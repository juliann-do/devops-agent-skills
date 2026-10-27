# AGENTS.md — torilab workspace

This file is read by both **Codex CLI** and **Claude Code** (via its `AGENTS.md`/`CLAUDE.md` convention) whenever either agent is launched with `torilab/` as the working directory. Keep it accurate as the workspace changes.

## What this is

`torilab/` is **not a single git repository**. It is a plain folder that groups many independent git clones by category. There is no root-level build, test, or lint system — each subdirectory below is its own repo with its own remote, history, and tooling.

## Layout

### `claude-skills-devops/` — agent skill collections (4 unrelated repos)
- **`devops-skills/`** (origin: `NotHarshhaa/devops-skills`) — our DevOps advisor skill plugin. Flat layout: `audit/`, `cost/`, `daily-task/`, `db-review/`, `docker-review/`, `dr-review/`, `friday-logwork/`, `incident/`, `k8s-review/`, `observability/`, `pipeline-review/`, `release-readiness/`, `runbook/`, `security-review/`, `terraform-review/`, each with one `SKILL.md`, plus `.claude-plugin/plugin.json`. **Every skill here is a strictly read-only advisor** — they inspect and write remediation plans, never apply changes — **except `friday-logwork/`**, which creates native Jira worklogs for Julian in project INF, plus 7h on HAE-17 for each Vietnam public holiday, time off on that month's MISC absence ticket, and overtime on top of the 7h through the Tempo API with the worklog's OT checkbox ticked (needs `TEMPO_API_TOKEN`; additive only: it never edits or deletes a worklog, never calls Tempo `PUT`/`DELETE`, and never touches issue fields, and it asks about annual leave, partial-day absences, and overtime before logging), **and `daily-task/`**, which executes an INF deploy-request ticket: it confirms the service/env against `manifest/k8s-manifest` and the Cheercast clusters, opens one PR to `k8s-manifest` `main` (image tag, env, secret wiring), writes new secret keys to AWS Secrets Manager, runs the ticket's SQL (via the stg/uat jump host for non-prod, and the prod DB node `<PROD_DB_HOST>` for prod, where every table the SQL changes is backed up first even if the ticket does not ask), and runs post-deploy commands once the user confirms the PR is merged. It never merges, deletes, or ArgoCD-syncs, and confirms before every write. These are also installed globally at `~/.claude/skills/` and `~/.codex/skills/`; keep all three copies in sync when a skill changes.
- **`skills/`** (origin: `mattpocock/skills`) — third-party, unrelated general-purpose skill collection. Has its own `CLAUDE.md`/`AGENTS.md`. Leave as-is; do not merge its content here.
- **`firstmate/`** (origin: `kunchenguid/firstmate`) — third-party multi-agent orchestration tool with its own large `AGENTS.md`. Fully self-contained. Leave as-is.
- **`tools-for-devops-agent/`** (origin: `aws/tools-for-devops-agent`) — AWS's official sample repo (MCP servers, custom agents, CloudFormation) for their DevOps agent. Reference/vendored, not ours.

### `manifest/` — Kubernetes / Helm manifests (7 repos)
- `k8s-manifest`, `a2v-infra.k8s-manifest`, `nem-recall-helm-charts`, `sns-infrastructure-helm-chart`, `non-prod-helm-charts`, `sre-non-prod-infra-charts` — our infra (mostly `torilab-ai` org).
- Each Cheercast cluster runs **two Prometheus servers**: kube-prometheus-stack in `monitoring` (`k8s-manifest/helm/kube-prometheus-stack/`; Grafana data sources `prod-prometheus` / `staging-prometheus` / `uat-prometheus`) and a prometheus-community chart in `<env>-monitoring` that owns the blackbox URL probes (prod: `torilab-ai/sre-prod-infra-charts` → `helm/monitoring/prometheus`, ArgoCD app `prometheus` with auto-sync + prune; stag/uat: `sre-non-prod-infra-charts/helm/monitoring/prometheus/`; Grafana data sources `prod-cheercast-prometheus` / `stag-cheercast-prometheus` / `uat-cheercast-prometheus`). The second Prometheus has its own node-exporter **disabled** and scrapes kube-prometheus-stack's node-exporter, so that DaemonSet must stay. Loki data sources are `prod-cheercast-loki` / `stag-cheercast-loki` / `uat-cheercast-loki`.
- Grafana (`<GRAFANA_HOST>`) runs outside Kubernetes on the EC2 `logging-system-graylog` (docker-compose v1 in `/data/grafana`, `nestedFolders` feature flag on). The standard dashboards live under the **Overview** folder, are tagged `torilab-standard`, and use only the `<env>-cheercast-prometheus` / `-loki` data sources; the older dashboards stay on their original data sources.
- `dify-helm` — vendored third-party fork (`BorisPolonsky/dify-helm`) for deploying Dify. Don't modify upstream logic casually.
- Typical commands: `helm lint`, `helm template`, `helm upgrade --install ...`. No Makefile/package.json in this tree.

### `terraform/` — AWS infrastructure as code (8 repos + 1 empty placeholder dir)
- `terraform` (Cheercast/Castalk AWS infra), `terraform-eks-module`, `terraform-efs-module` (EFS module ported from `terraform-aws-modules/terraform-aws-efs` v2.2.1, consumed via `?ref=<tag>`), `sns-infrastructure-terraform`, `sre-terraform-bb-vn-uat`, `sre-terraform-torilab-prod`, `a2v-infra.terraform`, `aia-terraform`.
- `terraform-module/` is currently an empty dir, no `.git`.
- Typical commands: `terraform fmt`, `terraform validate`, `terraform plan`. **Never run `terraform apply`/`destroy` unless explicitly asked** — these repos manage real dev/uat/prod infra, with state in S3 per environment per repo README.
- ⚠️ **Safety constraint**: `sns-infrastructure-terraform` and `aia-terraform/backends/uat/` have **committed `.tfstate` / `.tfstate.backup` files** in-tree. These can contain secrets and sensitive resource data. Never `cat`/print/display their contents; treat them as read-only and do not touch them unless the task specifically requires it.

### `services/` — application code
- `ai-agent-world/` — local git repo (no remote yet): multi-agent dev platform (FastAPI + LangGraph backend in `services/api`, Next.js/React Three Fiber dashboard in `apps/web`, Docker Compose stack). Has its own `AGENTS.md`/`README.md`; use its `Makefile` (`make test`, `make lint`, `make up`; `make up-host` + `make run-host` runs API/worker on the Mac so agents can use the Claude Code login, `~/.claude` skills/agents and MCP servers). Compose binds only to `127.0.0.1` and the worker mounts the Docker socket to start sandboxes. Its local `.env` holds generated secrets; never print it.
- `llm-agent/` (origin: `torilab-ai/llm-agent`) — has its own `AGENTS.md`/`CLAUDE.md`; follow those.
- `buzzencer/`, `wordpress/` — folders of service checkouts (SNS/Buzzencer apps, WordPress sites); each subfolder is its own project.
- `docker-compose/` — loose compose/nginx/php files, not a git repo.

### Other top-level folders
`CICD/torilab-shared-workflow`, `extension/go-browser-extension`, `interview/ai-mock-interviewer`, `torilab-ansible/` (origin: `torilab-ai/torilab-ansible`, has its own `AGENTS.md`), and `docs/reference/` (reference images).

## Working rules for agents

1. Each subdirectory under `claude-skills-devops/`, `manifest/`, `terraform/` is an independent git repo. `cd` into the specific repo before running `git` commands — don't assume shared history across the workspace or run `git` from the `torilab/` root.
2. There is no unified build/test/lint command. Use each repo's own tooling (`terraform fmt/validate`, `helm lint`, or npm scripts inside `skills/`).
3. Respect the nested `AGENTS.md`/`CLAUDE.md` already present inside `firstmate/` and `skills/` — they are self-contained and take precedence within their own subtree.
4. Never read/print `.tfstate`, `.tfstate.backup`, or similar state/secret files verbatim.
5. Terraform and Helm changes affect shared dev/uat/prod infrastructure — always propose a plan/diff first, never apply/deploy/upgrade without explicit confirmation.
6. When reviewing this workspace's own IaC (`terraform/`, `manifest/`), prefer the read-only skills in `claude-skills-devops/devops-skills/` (`terraform-review`, `k8s-review`, `dr-review`, etc.) over ad-hoc review.
7. **Never delete any resource anywhere — cloud (AWS/EKS/S3/etc.), Kubernetes, GitHub (repos/branches/issues/PRs), Atlassian (Jira issues/Confluence pages), or local files — without the user's explicit, in-the-moment confirmation.** This applies regardless of what a tool or credential technically permits (the AWS SSO profile below is AdministratorAccess — broad access is not standing permission to delete). Prefer read-only/inspect operations by default; if a task seems to require a delete, stop and ask first.
8. Keep code comments short: at most 1–2 lines saying what a function or block does. No multi-paragraph comments, no comments restating the code, no change history in comments; that belongs in the PR or commit message.

## MCP servers available (Claude Code + Codex CLI)

Installed at user/global scope, so available in every project, not just `torilab/`:

- **`atlassian`** — Jira/Confluence at `<your-org>.atlassian.net`, via `https://mcp.atlassian.com/v2/mcp` (OAuth).
- **`github`** — repo/issue/PR read access via `https://api.githubcopilot.com/mcp/`, bearer token sourced from `gh auth token` (Codex reads it from the `GITHUB_PAT` env var set in `~/.zshrc`; do not hardcode the raw token anywhere).
- **`aws-docs`** — `awslabs.aws-documentation-mcp-server`, public AWS docs lookup, no AWS credentials needed.
- **`eks`** — `awslabs.eks-mcp-server`, installed **without** `--allow-write`/`--allow-sensitive-data-access`, so it is read-only diagnostics against the `<AWS_SSO_PROFILE>` AWS SSO profile (`ap-northeast-1`). Keep it that way per rule 7 above.
- **`kubernetes`** — `containers/kubernetes-mcp-server` (`npx -y kubernetes-mcp-server@latest --config ~/.config/kubernetes-mcp-server/config.toml`). The shared TOML sets `read_only = true` and toolsets `core,config,helm` (v0.0.69+ dropped the `--read-only` flag, so the config file is required). Reads `~/.kube/config`, so it reaches every context (`bbvn-uat`, `cheercast-prod/staging/uat`) across both AWS accounts; needs the matching AWS SSO sessions active. Keep it read-only per rule 7.
- **`aws-cost`** — `awslabs.billing-cost-management-mcp-server` (successor to the deprecated `cost-explorer-mcp-server`), read-only cost/billing reporting against `<AWS_SSO_PROFILE>`.
- **`terraform`** — HashiCorp's official `hashicorp/terraform-mcp-server:0.4.0` (replaces AWS Labs' deprecated Terraform MCP server), run via `docker run -i --rm ...`. Provides Terraform Registry/provider docs and HCP Terraform remote-run tools — it does **not** wrap local `terraform plan/apply` execution, so local CLI commands (`terraform fmt/validate/plan`) are still how agents interact with this workspace's `.tf` files directly.
- **`google-sheets`** — Google's first-party Sheets MCP at `https://sheetsmcp.googleapis.com/mcp/v1` (OAuth). Claude Code gets it from the **claude.ai Google Sheets connector** (enabled in claude.ai settings, alongside Gmail/Drive/Calendar), so there is no local `google-sheets` entry in `~/.claude.json`; Codex has its own `[mcp_servers.google-sheets]` entry. Read/write access to Google Sheets. Treat writes to shared sheets as real changes — rule 7 applies.
- **`context7`** — Upstash Context7 at `https://mcp.context7.com/mcp` (no auth). Version-specific, up-to-date docs for libraries/frameworks/tools (Helm, Terraform providers, Kubernetes, SDKs). Ask for "use context7" or let the agent resolve a library ID then fetch its docs.
- **`grafana`** — Grafana's official `mcp-grafana` (`uvx mcp-grafana@latest --disable-write`, so read-only) against `https://<GRAFANA_HOST>`: search dashboards, read panels, query the Prometheus/Loki data sources. The token comes from `GRAFANA_SERVICE_ACCOUNT_TOKEN` in `~/.zshrc` (a Viewer-role Grafana service account): Claude expands `${GRAFANA_SERVICE_ACCOUNT_TOKEN}` from its config, and Codex forwards it via `env_vars`. Never hardcode the token in either config.
- **`sonarqube`** — SonarSource's `sonarsource/sonarqube-mcp:1.29.0.4488` (Docker, `SONARQUBE_READ_ONLY=true`) against `https://<SONARQUBE_HOST>` (Community Build on stag, `manifest/sre-non-prod-infra-charts/helm/monitoring/sonarqube`): projects, issues, quality gates, hotspots, coverage. Token is the `admin` user token `claude-codex-mcp` (USER token, expires 2027-01-18) in `SONARQUBE_TOKEN` in `~/.zshrc`, next to `SONARQUBE_URL`: Claude expands `${SONARQUBE_TOKEN}` from its config, Codex forwards both via `env_vars`. Needs Docker (Colima) running. Regenerate the token under My Account → Security as `admin` before it expires.
- **Web reading** — Claude Code uses its built-in `WebFetch`/`WebSearch` tools. Codex gets the same via `web_search = "live"` in `~/.codex/config.toml` plus the **`fetch`** MCP (`uvx mcp-server-fetch`, Codex only), which turns any URL into markdown.
- AWS-backed servers (`eks`, `aws-cost`) need an active AWS SSO session — run `aws sso login --profile <AWS_SSO_PROFILE>` if calls fail with an auth error.
- `grafana` fails to start until `GRAFANA_SERVICE_ACCOUNT_TOKEN` is exported in the shell that launched the agent.
- `terraform` needs the local Docker daemon (Colima) running — `docker ps` should succeed before it will connect.
- `atlassian` is OAuth-based — authenticate with `/mcp` in Claude Code. Codex needs `codex mcp login google-sheets` once for Sheets; in Claude Code, Sheets is signed in through the claude.ai connector.
