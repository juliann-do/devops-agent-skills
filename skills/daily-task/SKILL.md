---
name: daily-task
description: Execute a deploy-request Jira ticket (e.g. https://<your-org>.atlassian.net/browse/INF-8782) for Julian Do on the Cheercast EKS clusters. Reads the ticket description, works out which service and environment (prod / stag / dev-on-uat) it targets from k8s-manifest and the live cluster, confirms that with the user, then carries out the requested actions - image tag bumps, new env vars, new secrets (AWS Secrets Manager + ExternalSecret), all in ONE PR to k8s-manifest main; DB schema/data scripts and table backups via psql/pg_dump (through the stg/uat jump host for non-prod, and the prod DB node for prod, where every table the SQL changes is backed up first even if the ticket does not ask); and post-deploy commands exec'd into the container once the user confirms the PR is merged. Not read-only - it opens PRs, writes secrets, and runs SQL - so every write is gated on an explicit confirmation. Use when given an INF deploy ticket URL, or asked to "do this ticket", "run the deploy ticket", "daily task", or similar.
license: MIT
metadata:
  author: devops-skills contributors
  version: "1.0.0"
---

# Daily Task — deploy-request ticket runner

You are Julian Do's SRE assistant. Given one Jira deploy-request ticket, you
work out exactly what it asks for, verify where it applies, and carry it out
through the normal channels: GitOps PRs for anything ArgoCD owns, direct
`psql` for DB scripts, `kubectl exec` for post-deploy commands. These
instructions are written for an agent with zero context on this project:
follow the phases in order and do not improvise around a gate.

> **Before reusing this skill for someone else:** the environment block
> below (clusters, jump hosts, key path, repo path) is specific to one
> person's machine. Replace it before running elsewhere.

## Environment

| Thing | Value |
| ----- | ----- |
| Jira site / `cloudId` | `<your-org>.atlassian.net` |
| Manifest repo | `<WORKSPACE>/manifest/k8s-manifest` (`git@github.com:torilab-ai/k8s-manifest.git`, default branch `main`) |
| Helm charts | `helm/apps/<service>/values-<env>.yaml` (`imageTag:` is the first key) |
| ArgoCD apps | `argocd/overlays/{prod,stag,uat}/apps/**/<service>.yaml` - `valueFiles` + `destination.namespace` tell you env and namespace |
| AWS account / profile | `<AWS_ACCOUNT_ID>` / `<AWS_SSO_PROFILE>` (`ap-northeast-1`). Re-login: `! aws sso login --profile <AWS_SSO_PROFILE>` |
| Image registry | `<AWS_ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/<service>` |
| Secrets | `ExternalSecret` in the values file's `additionalManifests`, `ClusterSecretStore` `ai-aws-vault`, Secrets Manager key `eks-cheercast-<env>-<service>` |
| SSH key | `~/.ssh/jumphost-rsa`, user `ubuntu` |
| Backup dir (jump host / prod DB node) | `/home/ubuntu/jira-ticket/` |

Environment map (verify per service - the ArgoCD app is the source of truth):

| Env | Values file | ArgoCD overlay | kube context | Typical namespace | DB reachable from | Jump host |
| --- | ----------- | -------------- | ------------ | ----------------- | ----------------- | --------- |
| prod | `values-prod.yaml` | `argocd/overlays/prod` | `cheercast-prod` | `castalk-prod` | local machine for short one-off statements; prod DB node for backups and long SQL files | `<PROD_DB_HOST>` (private IP, same key/user) |
| stag | `values-stag.yaml` | `argocd/overlays/stag` | `cheercast-staging` | `castalk-stag` | jump host only | `<HOST_IP>` |
| dev (runs on the **uat** cluster) | `values-dev.yaml` | `argocd/overlays/uat/apps/dev` | `cheercast-uat` | `castalk-dev` | jump host only | `<HOST_IP>` |
| uat | `values-uat.yaml` (if it exists) | `argocd/overlays/uat` | `cheercast-uat` | from the app file | jump host only | `<HOST_IP>` |

## Hard rules

1. **Never delete anything** - no `kubectl delete`, no branch/PR/secret/
   secret-key deletion, no `DROP`/`TRUNCATE`/`DELETE` you wrote yourself, no
   removing files on the jump host. If the ticket's own SQL contains a
   destructive statement, show it to the user and get an explicit "yes, run
   it" for that statement specifically.
2. **GitOps only for workloads.** Image tags, env vars, and secret wiring
   change via a PR to k8s-manifest `main`. Never `kubectl set image`,
   `kubectl edit`, `kubectl patch`, `helm upgrade`, or ArgoCD sync/rollback
   yourself. **Never merge the PR** - the user merges.
3. **One PR per ticket** to k8s-manifest, covering every manifest change the
   ticket needs (tag + env + secret refs together).
4. **Secrets never appear in chat, files in the repo, PR text, or shell
   history.** Read them from the pod/Secrets Manager straight into the
   command that needs them (pipe / stdin). When you must show that a value
   exists, show the key name and its length, never the value.
5. **Confirm before every write**, with the exact thing about to happen:
   the env/service (Phase 1 gate), the PR diff, each secret key being added,
   each SQL file + target DB, each post-deploy command. A confirmation for
   one step does not carry over to the next.
6. **Respect the deploy window.** If the ticket says "This deploy should
   start at" a time (UTC+7) later than now, tell the user and ask before
   doing any prod write (PR creation is fine; DB writes and post-deploy
   commands are not).
7. **Stop on surprise.** SSO expired, cluster unreachable, tag not in ECR,
   current deployed tag ≠ the ticket's rollback tag, migration already
   applied, psql version mismatch you can't resolve - stop and ask; do not
   work around it silently.

## Sources and reasoning

- **Link what you researched.** When a conclusion rests on research (vendor or
  tool docs, chart/provider docs, release notes, a GitHub issue, a Jira or
  Confluence page), end it with a **References** list: one link per line plus
  what it supports. Mark any conclusion with no source as your own inference.
- **Say why before you trace.** Before reading logs, events, metrics, traces,
  or error output, state in one line what you are looking for and which
  symptom or hypothesis it tests; afterwards, say what it showed. Never dump
  logs without that reason.

## Phase 0 - Read the ticket

1. Fetch the issue with the Atlassian MCP `getJiraIssue` (`cloudId`
   `<your-org>.atlassian.net`, key from the URL, e.g. `INF-8782`). Read the
   description fully, plus comments (requesters often add late changes
   there).
2. Extract into a checklist - write `N/A` where the ticket says so or is
   blank:
   - **Image** (`Version`) - repo name → service; tag.
   - **Rollback image**.
   - **Deploy start time** (UTC+7) and linked tickets/due dates (context only).
   - **Config update** - new/changed env vars.
   - **Secret update** - new keys (the ticket only names them; values come
     from the user).
   - **Migration** - DB script links (schema / data), and whether a
     **backup** is requested.
   - **Command after image deployment**, in order.
   - **Affected services**.
3. Anything ambiguous (e.g. "update config" with no key names) → ask the
   user now, in one consolidated question.

## Phase 1 - Assessment (where does this run?)

1. **Pull the newest manifest code** - never assess from a stale checkout:
   ```bash
   cd <WORKSPACE>/manifest/k8s-manifest
   git status --porcelain            # must be empty; if not, stop and ask
   git switch main && git pull --ff-only
   ```
2. **Find the service**: the image repo name (the part after `.amazonaws.com/`)
   is normally the chart directory `helm/apps/<service>/`. Confirm by
   grepping for the repository string:
   `grep -rl "<image repo>" helm/apps argocd`.
3. **Find candidate envs**: list the ArgoCD apps for the service in every
   overlay and read each one's `valueFiles` and `destination.namespace`.
4. **Narrow to one env** using all of these signals, and say which ones
   agree:
   - The tag's env marker (`...-prod-...`, `-stag-`, `-dev-`, `-uat-`).
   - The ticket's **rollback image** - it should equal the `imageTag`
     currently in exactly one values file.
   - The ticket title / scope wording.
5. **Verify on the live cluster** (read-only):
   ```bash
   kubectl --context <ctx> -n <ns> get deploy -l app.kubernetes.io/instance=<release> \
     -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image
   ```
   (If the label selector returns nothing, `get deploy` and pick by name.)
   Check every deployment of the release (web, worker, beat). If any
   `kubectl` call fails with an auth/token error, **stop** and ask the user
   to run `! aws sso login --profile <AWS_SSO_PROFILE>`, then retry.
6. **Check the new tag exists in ECR**:
   ```bash
   aws ecr describe-images --profile <AWS_SSO_PROFILE> --region ap-northeast-1 \
     --repository-name <service> --image-ids imageTag=<new tag> \
     --query 'imageDetails[0].imagePushedAt'
   ```
   Not found → stop and tell the user (the requester must push it first).
7. **Gate - confirm with the user** before any write. Show:

   > **INF-XXXX assessment**
   > | | |
   > |-|-|
   > | Service / chart | `llm-counseling-backend` → `helm/apps/llm-counseling-backend` |
   > | Env / cluster / ns | prod / `cheercast-prod` / `castalk-prod` |
   > | Values file | `values-prod.yaml` |
   > | Live image (all deploys) | `1d48af8-prod-261005.1114` (= ticket rollback ✅) |
   > | New tag | `2db2195-prod-261007.1152` (in ECR ✅, pushed 2026-10-07 11:52) |
   > | Deploy window | 2026-10-07 14:00 (+07) - now 13:10, 50 min early |
   > | Plan | 1) DB schema script 2) PR: image tag 3) after merge: `fix_invalid_kp`, then `fix_invalid_kp --live` |
   >
   > Correct?

   Do not continue until the user says yes (or corrects you).

## Phase 2 - Manifest PR (image tag, env, secrets — one PR)

Skip this phase entirely if nothing in the checklist touches the chart
(e.g. the tag is already the requested one and there is no config/secret
change) - say so.

1. Branch from fresh `main`: `git switch -c <ticket-key>-<service>-<env>`
   (e.g. `INF-8782-llm-counseling-backend-prod`).
2. **Image tag**: change `imageTag:` in `values-<env>.yaml` - only if it
   differs from the requested tag. If it is already equal, note "tag
   already set" and change nothing.
3. **New env vars**: add them to the `env:` map of `values-<env>.yaml`,
   values quoted as strings, next to related keys. If the chart has no
   `env:` map or wires env differently, read `templates/deployment.yaml`
   (and `templates/worker*/`) and follow the chart's own mechanism.
4. **New secrets** (do Secrets Manager first, then the chart):
   1. Find the Secrets Manager key from the `ExternalSecret`
      `remoteRef.key` in `values-<env>.yaml` (e.g.
      `eks-cheercast-prod-llm-counseling-backend`).
   2. List existing key **names only**:
      ```bash
      aws secretsmanager get-secret-value --profile <AWS_SSO_PROFILE> --secret-id <key> \
        --query SecretString --output text | jq -r 'keys[]'
      ```
   3. For each new key: if it already exists, ask before overwriting.
      Otherwise ask the user to type the value. Do not echo it back.
   4. Merge and write without the value touching disk or chat:
      ```bash
      aws secretsmanager get-secret-value --profile <AWS_SSO_PROFILE> --secret-id <key> \
        --query SecretString --output text \
      | jq -c --arg k "<NEW_KEY>" --arg v "<value>" '. + {($k): $v}' \
      | aws secretsmanager put-secret-value --profile <AWS_SSO_PROFILE> --secret-id <key> \
          --secret-string file:///dev/stdin
      ```
      Re-run step 2 and confirm the new key name is listed.
   5. Add one entry per key to the `ExternalSecret` `spec.data` list in
      `values-<env>.yaml`, matching the existing style exactly:
      ```yaml
      - secretKey: NEW_KEY
        remoteRef:
          key: eks-cheercast-<env>-<service>
          property: NEW_KEY
      ```
      The pod picks it up via the existing `envFrom.secretRef` - no other
      wiring needed. If the chart has no ExternalSecret for this env, stop
      and ask how the user wants it wired.
5. **Validate**:
   ```bash
   helm lint helm/apps/<service> -f helm/apps/<service>/values-<env>.yaml
   helm template <release> helm/apps/<service> -f helm/apps/<service>/values-<env>.yaml > /dev/null
   git diff
   ```
   The diff must touch only `values-<env>.yaml` (plus anything the ticket
   explicitly asked for). Show the diff to the user.
6. **Open the PR** to `main` after the user OKs the diff:
   ```bash
   git commit -am "<ticket-key>: <service> <env> - <short summary>"
   git push -u origin HEAD
   gh pr create --base main --title "<ticket-key>: <service> <env> - <summary>" --body "<body>"
   ```
   Body: ticket link, what changed (tag old → new, env keys, secret key
   **names**), rollback tag, and that DB/post-deploy steps are handled
   outside the PR. Give the user the PR URL. **Do not merge.**

## Phase 3 - Database work

Do this before the user merges the PR, unless the ticket says the script
must run after the new image is live - then do it after Phase 4 step 2.

### 3a. Get the script

Fetch every linked SQL file from GitHub (works for private repos):
```bash
gh api -H "Accept: application/vnd.github.raw" \
  "repos/<owner>/<repo>/contents/<url-decoded path>?ref=<branch>" > <scratchpad>/<ticket-num>_<name>.sql
```
Show the full SQL to the user. Flag anything destructive (`DROP`,
`TRUNCATE`, `DELETE`/`UPDATE` without `WHERE`, column type changes on big
tables) and anything that takes a long lock.

### 3b. Get connection details from the pod

Read the DB env from the running app container - names and non-secret
values only in chat:
```bash
kubectl --context <ctx> -n <ns> exec deploy/<service> -- printenv \
  | grep -E '^(POSTGRES|DB_|DATABASE)' | grep -viE 'PASS|SECRET'
```
Most services use `POSTGRES_HOST/PORT/DB/USER/PASSWORD` (or a
`DATABASE_URL`). Cross-check against `values-<env>.yaml`. The password is
only ever piped (see 3d).

### 3c. Match the psql version

1. Where psql will run:
   - **stag / dev / uat** → the jump host.
   - **prod, any SQL that changes data or schema** (and so needs the
     mandatory backup, see 3d step 2), or a long SQL file → the prod DB
     node `<PROD_DB_HOST>`, exactly the same flow as stag: scp the file to
     `/home/ubuntu/jira-ticket/`, back up there, run inside tmux.
   - **prod, read-only queries only** (pre-checks, verification) → local
     (`nc -z -G 5 <host> 5432` first) or the prod DB node.
   ```bash
   ssh -i ~/.ssh/jumphost-rsa ubuntu@<jumphost-ip or <PROD_DB_HOST>>
   ```
   The prod DB node has psql/pg_dump 16 on the PATH, majors 14 and 16 under
   `/usr/lib/postgresql/`, and mysql/mysqldump.
2. Look at the jump host's tmux for how previous tickets were run, and run
   long operations inside tmux so they survive a dropped SSH session:
   ```bash
   tmux ls
   tmux capture-pane -p -t <session> -S -300   # read prior commands/patterns
   ```
3. Server version: run `SHOW server_version;` (step 3d pattern, read-only).
   Client version: `psql --version` / `pg_dump --version` where it will run.
4. Client **major** must equal server major (pg_dump refuses to dump a newer
   server; psql works across versions but use the same major anyway). If
   they differ, use the matching client: `/usr/lib/postgresql/<major>/bin/psql`
   on the jump host if present, else
   `docker run --rm -i postgres:<major> psql ...` - ask before installing
   any package on the jump host.

### 3d. Run the script

1. **Pre-check** (read-only): inspect the objects the script touches
   (`\d <table>`, row counts, or the specific column) to confirm it hasn't
   already been applied. Already applied → report and ask; never re-run
   blindly.
2. **Backup.** On **prod**, back up every table the script writes to
   (`INSERT`/`UPDATE`/`DELETE`/`ALTER`/`TRUNCATE` targets) **even when the
   ticket does not ask for it** - list the tables and their sizes in the
   step 3 confirmation. On non-prod, back up only if the ticket asks. A
   table the script only creates (`CREATE TABLE`) needs no backup. Dump as
   the app's own user (password piped from the pod, as in step 4) when it
   can read the table; if that fails with a permission error, ask the user
   for the admin DB user and password. On the jump host / prod DB node, into
   `/home/ubuntu/jira-ticket/<ticket_number>_<table_name>.sql` (ticket
   number = digits only, e.g. `8782`):
   ```bash
   mkdir -p /home/ubuntu/jira-ticket
   PGPASSWORD='<admin pass>' pg_dump -U <admin user> -h <host> -p 5432 -d <db> \
     -t <schema>.<table> > /home/ubuntu/jira-ticket/<ticket_number>_<table_name>.sql
   ls -lh /home/ubuntu/jira-ticket/<ticket_number>_<table_name>.sql
   ```
   (Whole-DB backup only when asked: drop `-t`, and name the file
   `<ticket_number>_<db_name>.sql`.) Prefix the command with a space so it
   stays out of shell history, and confirm the file is non-empty before
   continuing.
3. **Confirm**, showing: target env, host, DB, user, the SQL file, and the
   exact command.
4. **Run** with the app's own credentials, password piped from the pod, in
   one transaction, stopping on the first error. Non-prod (copy the SQL
   to the jump host first with `scp -i ~/.ssh/jumphost-rsa`):
   ```bash
   kubectl --context <ctx> -n <ns> exec deploy/<service> -- printenv POSTGRES_PASSWORD \
   | ssh -i ~/.ssh/jumphost-rsa ubuntu@<jumphost-ip> \
       'IFS= read -r PGPASSWORD; export PGPASSWORD;
        psql -h <host> -p <port> -U <user> -d <db> -v ON_ERROR_STOP=1 --single-transaction \
             -f /home/ubuntu/jira-ticket/<ticket_number>_<name>.sql'
   ```
   Prod: the same command against `ubuntu@<PROD_DB_HOST>`, after the
   mandatory backup in step 2. Never run a data-changing prod statement
   that skipped the backup.
   If the app has only a `DATABASE_URL`, pipe that instead and pull the
   password out on the remote side; never print it.
   If the script has statements that cannot run in a transaction
   (`CREATE INDEX CONCURRENTLY`, `VACUUM`), drop `--single-transaction` and
   tell the user why.
5. **Verify**: re-run the pre-check and show before/after.

## Phase 4 - After the PR is merged

1. Ask the user: "PR <url> - merged?" and wait. Then verify it yourself:
   `gh pr view <url> --json state,mergedAt` must show `MERGED`.
2. Wait for ArgoCD to roll it out (read-only):
   ```bash
   kubectl --context <ctx> -n <ns> rollout status deploy/<service> --timeout=10m
   kubectl --context <ctx> -n <ns> get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image,READY:.status.readyReplicas
   ```
   Every deployment of the release must show the new tag and be Ready. If
   it hasn't changed after ~10 min, tell the user (ArgoCD may need a manual
   sync, which is theirs to do) - do not sync it yourself.
3. **Post-deploy commands**, in the ticket's order, inside the web
   container of a new-image pod:
   ```bash
   kubectl --context <ctx> -n <ns> exec deploy/<service> -c <container> -- <command>
   ```
   - Confirm each command before running it.
   - When the ticket lists a dry run followed by a live run (e.g.
     `fix_invalid_kp` then `fix_invalid_kp --live`), run the dry run, show
     its output, and get an explicit go-ahead for the live one.
   - Long-running commands: tell the user, and use a generous
     `--request-timeout` / run them with `nohup ... &` only if the user
     agrees. Stop at the first non-zero exit.
4. Check pod logs briefly for errors after the rollout
   (`kubectl logs deploy/<service> --since=10m | grep -iE 'error|traceback' | tail`).

## Phase 5 - Report

Summarise, in this order:

- Ticket, service, env, cluster/namespace.
- PR URL and state; tag old → new.
- Secrets Manager key names added (never values).
- DB: script(s) run, target DB, backup file path, before/after check.
- Post-deploy commands and their result.
- Rollback: the ticket's rollback image, and that rolling back means a PR
  reverting `imageTag` (schema changes are not reverted by that - say so).
- Anything skipped or still pending.

Then ask whether to post this summary as a comment on the Jira ticket; post
it only on a yes.
