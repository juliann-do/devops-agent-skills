---
name: migrate-to-eks
description: Migrate a service from the docker-compose stack on EC2 to the bbvn-uat EKS cluster - assess the running service, create its ECR repository in Terraform, write the Helm chart, and wire up CI/CD. Use when asked to migrate a service to Kubernetes or EKS, move something off docker-compose, or containerise an existing EC2 workload for the cluster. Takes a service name and repo name. Read-only on the EC2 host; every change goes through a PR that is reviewed before merge.
---

# Migrating a service to EKS

Proven end to end on `sns-sso` (Keycloak). That migration is the reference —
when something here is ambiguous, look at what `sns-sso` actually does.

**Inputs:** service name (e.g. `sns-sso`) and repo name (e.g. `torilab-ai/sns-sso`).

## Three rules that override everything

**The EC2 host is read-only.** Read compose files, nginx vhosts and env files to
understand the service. Change nothing there. The old stack stays running as the
rollback until cutover.

**In the service repo, touch only `.github/workflows/` and the `Dockerfile`.**
Nothing under `src/`, no `pom.xml`, no `package.json`, no application config
(`application*.yml`). That code belongs to the dev team, who are shipping
features on the same branches; a migration commit landing in `src/` collides
with their work and makes the migration answerable for behaviour it did not
write.

This holds even when the migration is clearly blocked by something in the code
— a hardcoded hostname, a path the chart cannot satisfy, a config key with no
`${}` placeholder. Those are real findings and they belong in the report, named
with file and line, as work for the dev team. They are not yours to fix.

Two consequences in practice:

- Prefer a chart-side answer. A file the app insists on reading from a fixed
  path is a mounted Secret, not an edit to `application-uat.yml`. Spring's
  relaxed binding means most config can be overridden by an environment
  variable without touching the file at all.
- The CI/CD PR's diff must stay at exactly `ci.yml` and `cd.yml`. Check it
  (`gh pr diff <n> --name-only`) before asking for review. Merging the base
  branch into yours to pick up newer commits is fine and does not widen that
  diff — the commits are already in the base.

**Review before every merge.** Open the PR, report what it does and what it will
break, and wait. This applies to all four repos. Nothing merges on your own
judgement, including when a previous PR in the same sequence was approved.

## Order of work

Each step depends on the last. Do not parallelise — an ECR repository that does
not exist yet makes the chart untestable, and a chart that has never rendered
makes CI meaningless.

### 1. Assess the running service

The repo is not the source of truth; the EC2 host is. The compose file that runs
in UAT lives on the box, not in git.

```bash
ssh -i ~/.ssh/jumphost-rsa ubuntu@<app-host> \
  'cat /opt/buzznet/source/SourceCode/deploy_uat/docker-compose.uat.<service>.yml'
ssh -i ~/.ssh/jumphost-rsa ubuntu@<app-host> \
  'cat /etc/nginx/sites-enabled/<domain>.conf'
```

`ec2-user@<HOST_IP>` is the jump host inside the cluster VPC (private
`<PRIVATE_IP>`); `ubuntu@` is the application host. Try both users — they differ per
box.

Answer these before writing anything:

- **Ports** — what the container listens on, and any separate management/health
  port. Keep management ports off the Ingress; they are usually unauthenticated.
- **Database** — engine, and *which* instance. See the VPC trap below.
- **Redis / cache** — is there one, and is it shared?
- **Domain and nginx** — read the vhost in full. Look for `allow`/`deny` blocks,
  `location = /` redirects, `proxy_cookie_flags`, and buffer sizes. A naive
  catch-all Ingress silently drops restrictions the vhost was enforcing.
- **Secrets** — every value in the compose `environment:` block. Assume all of
  them are disclosed: they sit in plaintext on the box and often in the repo too.
- **Entrypoint** — read it. Services here transform their own environment
  (`sns-sso` strips an `ENV_` prefix and substitutes `REALM_*` into a template),
  so variable names in values are not always what the app reads.
- **Logging** — drop file logging. promtail ships stdout to Loki; a file sink
  needs a volume nothing reads.

Then check the service repo: does it have a `uat` branch? The CI/CD flow assumes
`feature/* → uat → main`. If there is no `uat` branch, stop and ask — that is a
branching decision, not something to create silently.

### 2. ECR repository (Terraform)

Repo: `torilab-infrastructure-nonprod`, path
`<AWS_SSO_PROFILE>/shared/ap-northeast-1`.

Every torilab image lives in account **<AWS_ACCOUNT_ID>**, not the cluster account.
Add an entry to `var.ecr_repositories` in `variables.tf` with
`namespace = "<project>"`, and consumer principals matching the existing a2v
repositories:

```hcl
"<service>" = {
  namespace = "buzzencer"
  consumer_role_arns = [
    "arn:aws:iam::<AWS_ACCOUNT_ID>:root", # bb-vn, bbvn-uat-eks-clt
    "arn:aws:iam::<AWS_ACCOUNT_ID>:root", # bb-vn
  ]
}
```

Account-root principals, not role ARNs — verified against `a2v/ams-api`. The
consuming account's own IAM still gates the pull, so it is not a widening.

**Flow:** open a PR to `main` → review → comment `terraform plan` on the PR →
when the plan is right, comment `terraform apply` → merge after it succeeds.
That ordering is deliberate: apply runs the exact reviewed plan, and merging
before applying would leave `main` describing infrastructure that does not exist.

### 2b. Build and push the first image by hand

CI cannot do this yet — its own workflows do not exist until step 4, and the
chart in step 3 needs a real tag to deploy. So the first image is built
manually, once.

**`--platform linux/amd64` is mandatory.** Almost everyone here builds on an
Apple-silicon Mac, where the default is arm64. An arm64 image pushes to ECR
happily and then fails only at pod start, with `exec format error` buried in a
CrashLoopBackOff — it looks like a broken entrypoint, not a wrong architecture.

```bash
cd <service repo> && git checkout uat && git pull
SHA=$(git rev-parse --short HEAD)
REPO=<AWS_ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/buzzencer/<service>

aws ecr get-login-password --region ap-northeast-1 --profile <AWS_SSO_PROFILE> \
  | docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com

docker build --platform linux/amd64 -t "$REPO:uat-$SHA" .
docker push "$REPO:uat-$SHA"

# confirm the manifest really is amd64 before wiring it into values
docker manifest inspect "$REPO:uat-$SHA" | grep -A2 platform
```

Use `uat-<short sha>` — the same shape CD produces later, so the chart does not
change form when CI takes over. The repository is IMMUTABLE: a fix means a new
commit and a new tag, never a re-push.

Put that exact tag in `values-<env>.yaml`. A chart carrying a tag that was never
pushed renders fine and fails at pull time, which is the slowest way to find out.

### 3. Helm chart

Repo: `non-prod-helm-charts`, path `helm/uat/<project>/<service>/`. Read that
repo's `AGENTS.md` first. Model on `helm/uat/buzzencer/sns-sso`.

A chart is two edits, always: the chart itself, and a release entry in
`applications/bbvn-uat/values.yaml`. A chart with no release declaration deploys
nothing.

Secrets come from AWS Secrets Manager through the `ai-aws-vault`
ClusterSecretStore — copy `templates/secret.yaml` from
`a2v/aibot-ai-bothub-api`. The secret lives in account **<AWS_ACCOUNT_ID>**,
`ap-northeast-1` (the cluster account, not the registry one), named
`uat-<project>-<service>`.

Create it by piping the compose file's own values into the API — never by
retyping them. Anything that passes through your visible output is in a
transcript, a scrollback and a shell history:

```bash
# 1. fetch the compose to a local temp file (not printed)
ssh -i ~/.ssh/jumphost-rsa ubuntu@<app-host> \
  'cat /opt/buzznet/source/SourceCode/deploy_uat/docker-compose.uat.<service>.yml' \
  > "$TMP/compose.yml"

# 2. split credential-shaped keys from plain config
python3 - <<'EOF'
import yaml, json, os
env = yaml.safe_load(open(f"{TMP}/compose.yml"))["services"]["<service>"]["environment"]
def is_secret(k):
    return any(t in k for t in ("SECRET","API_KEY","ACCESS_KEY","APP_KEY",
                                "HASH_KEY","TOKEN","WEBHOOK_URL","PASSWORD","USERNAME"))
json.dump({k:str(v) for k,v in env.items() if is_secret(k)},
          open(f"{TMP}/secret.json","w"), indent=2)
os.chmod(f"{TMP}/secret.json", 0o600)
EOF

# 3. push, verify by key NAME only, then shred
aws --profile twomi --region ap-northeast-1 secretsmanager create-secret \
  --name uat-<project>-<service> --secret-string "file://$TMP/secret.json"
aws --profile twomi --region ap-northeast-1 secretsmanager get-secret-value \
  --secret-id uat-<project>-<service> --query SecretString --output text \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)),"keys")'
shred -u "$TMP/secret.json"
```

Confirm External Secrets can read it before writing the chart — a policy
simulation is cheaper than a crashlooping pod:

```bash
aws --profile twomi iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::<AWS_ACCOUNT_ID>:role/<ROLE_NAME> \
  --action-names secretsmanager:GetSecretValue --resource-arns <secret-arn> \
  --query 'EvaluationResults[].EvalDecision' --output text     # => allowed
```

Client IDs travel with their secrets rather than into values, so a provider's
pair is never split across two files. Credentials copied from compose are
disclosed by definition — they sit in plaintext on the box — so rotate them once
the service is running, and prefer IRSA over copying static
`AWS_ACCESS_KEY_ID`/`SECRET` pairs into the secret at all.

Verify before opening the PR, and quote the output:

```bash
helm lint ./helm/uat/<p>/<s> -f .../values.yaml -f .../values-uat.yaml
helm template <s> ./helm/uat/<p>/<s> -f ... -n uat-<project> | \
  kubectl --context bbvn-uat apply --dry-run=server -f -
kubectl --context bbvn-uat diff -f -    # what actually changes
```

### 4. CI/CD

Copy `.github/workflows/ci.yml` and `cd.yml` from `sns-sso`. They call
`torilab-ai/torilab-shared-workflow` and only need `ecr_repository`,
`manifest_repo`, `values_file` changed.

CI builds on PRs into `uat` and is the only thing that ever builds an image. CD
runs on `pull_request: [closed]` with `merged == true` and *promotes* that image
by re-tagging — it never rebuilds. Do not "fix" CD to trigger on push; only the
PR event carries the head SHA that names the built image.

Test with a throwaway PR into `uat` before wiring anything real.

**Check the base has not moved before merging the CI/CD PR.**

```bash
git fetch origin
git rev-list --count <pr head sha>..origin/uat    # must be 0
```

CD promotes by `source_sha: head.sha` — the commit CI built. If `uat` gained
commits after that build, CD re-tags the older image as `uat-<merge sha>`, a tag
whose whole meaning is "this is the code at that commit". The promoted image
silently lacks whatever landed in between, and nothing reports it: CD does not
rebuild, by design, so it cannot notice its source predates the base.

This is the sharp edge of build-once-promote. It is correct when the PR head is
current and quietly wrong when it is not — and a CI/CD PR tends to sit open
longer than a feature PR, which is exactly when the base moves.

Fix by merging the base into your branch (`git merge origin/uat`) and letting CI
rebuild. That does not widen the PR diff, since those commits are already in the
base — verify with `gh pr diff <n> --name-only` that it is still just the two
workflow files.

After the first CD run, confirm the promotion rather than assuming it:

```bash
aws ecr describe-images --repository-name <ns>/<service> --profile <AWS_SSO_PROFILE> \
  --query 'imageDetails[].{tags:join(`,`,imageTags),digest:imageDigest}' --output table
```

`sha-<x>` and `uat-<y>` sharing one digest is the proof that nothing rebuilt.

**Do not write build-specific facts next to `image.tag`.** CD rewrites that
value on every merge, and `yq` preserves the surrounding comments — so a note
naming a commit or digest is wrong from the first promotion onward, while still
reading as fact. Comment on the mechanism (what owns the field, how to check
what is deployed) and let the value speak for the build.

## Cluster preconditions — where migrations actually fail

None of these are visible in the chart. All of them cost hours on `sns-sso`.

| Check | Why |
|---|---|
| **Which VPC is the database in?** | The compose endpoint may be in the *EC2* VPC (`10.20.x`), unreachable from the cluster (`10.0.x`). Symptom is a JDBC **timeout**, not an auth error. Look for an equivalent instance in `<VPC_ID>`. |
| **Does the DB security group admit the cluster?** | It must allow the **pod CIDRs** (`100.126.x`), not the node SG — VPC CNI custom networking gives pods their own addresses. |
| **Does every AZ have an ENIConfig?** | `kubectl get eniconfig`. Custom networking maps node→ENIConfig by zone label; a node in an AZ without one never becomes Ready and `aws-node` fails on `ipamd.sock`. |
| **Storage class** | `ebs-csi-sc`. EBS is zonal, so a PVC pins the pod to one AZ for good. |
| **Image tag exists** | The chart should refuse to render without an explicit tag. Never `:latest`. |

## Ingress, TLS and access

TLS terminates twice and never inside the cluster: Cloudflare, then ALB
`v3external` (ACM), then plain HTTP to nginx and the pod. Charts carry no `tls:`
block. Set `KC_PROXY_HEADERS`-style options so the app trusts `X-Forwarded-Proto`
and builds `https://` URLs.

- **Always a new hostname: the EXISTING one with `pre-` prefixed to its
  subdomain.** Derive it from the `server_name` in the nginx vhost you read in
  step 1 — not from the service name, which often differs from the hostname the
  world already uses.

  ```
  uat-buzznet-fe-api.buzzencer.com   ->  pre-uat-buzznet-fe-api.buzzencer.com
  uat-app-sso.buzzencer.com          ->  pre-uat-app-sso.buzzencer.com
  uat-sns.buzzencer.com              ->  pre-uat-sns.buzzencer.com
  uat-buzznet-batch.buzzencer.com    ->  pre-uat-buzznet-batch.buzzencer.com
  ```

  Only the first label gains `pre-`; the rest of the name and the domain are
  untouched. Keeping the rest identical is the point — at cutover the change is
  deleting `pre-`, so the old and new names line up and a diff of the two
  configs shows only what genuinely differs.

  This is what every migrated buzzencer service in `uat-buzzencer` already uses
  (`kubectl --context bbvn-uat -n uat-buzzencer get ingress`). Check that list
  before naming a new one, and match it rather than inventing a variant. Do not
  shorten or re-derive the name, and do not use the older `-k8s` suffix form.

  Never reuse the live hostname — the compose stack keeps serving it throughout
  and stays the rollback until cutover.

  Whatever the app uses to build its own URLs must be changed to match the new
  host exactly (for `sns-sso` that was `ENV_KC_HOSTNAME`). A mismatch does not
  fail at startup; it produces redirects to the wrong origin, which surfaces as
  login failures that look like networking bugs.

  Any external callback registered against the old host also needs the new one
  adding — OAuth redirect URIs are registered per-URI, so social login fails on
  the new host until the provider knows about it, while username/password keeps
  working and hides the problem.
- **Cloudflare record: CNAME to the ALB, proxied (orange).** ALB addresses
  rotate, so never an A record. Proxied is required: the controller resolves the
  client IP from `CF-Connecting-IP`, which only exists on proxied requests. A
  grey-cloud record makes every allowlist deny everyone, including you.
- **The ACM cert on `v3external` covers `*.aiavatar.fun` only.** For a
  `buzzencer.com` host, either add a cert to the listener or set that hostname to
  Cloudflare **Full** (not strict), which skips origin validation.
- **Allowlists hold client IPs, not the ALB's.** nginx rewrites `$remote_addr`
  before evaluating `allow`/`deny`.
- **`allow-snippet-annotations` is false**, so `configuration-snippet` is
  unavailable. A `location = /` redirect becomes its own Ingress with
  `pathType: Exact` + `temporal-redirect`.
- **Restricted paths need their own Ingress.** Annotations are per-Ingress, so
  scoping an allowlist to `/admin` without locking out users means separate
  objects; nginx picks the most specific location.

## Sources and reasoning

- **Link what you researched.** When a conclusion rests on research (vendor or
  tool docs, chart/provider docs, release notes, a GitHub issue, a Jira or
  Confluence page), end it with a **References** list: one link per line plus
  what it supports. Mark any conclusion with no source as your own inference.
- **Say why before you trace.** Before reading logs, events, metrics, traces,
  or error output, state in one line what you are looking for and which
  symptom or hypothesis it tests; afterwards, say what it showed. Never dump
  logs without that reason.

## Reporting

At each step say what was verified with which command, what is still unproven,
and what the next merge will change on the cluster. "Renders cleanly" is not
"works" — say which one you mean.

If an allowlist suddenly 403s the user, check their egress first:
`curl -6 -s https://ifconfig.me`. A VPN that tunnels only IPv4 leaks IPv6, and
the request arrives from an address no allowlist contains.
