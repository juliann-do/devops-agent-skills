# devops-agent-skills

DevOps agent skills, subagents, a safety hook and MCP config for **Claude Code** and **Codex CLI**.
All configs are sanitized: secrets come from env vars, and internal hosts/IPs/account IDs are `<PLACEHOLDERS>`.

## Layout

| Path | What |
|---|---|
| `skills/` | Skills, one `SKILL.md` each (plus `docs/` shared templates) |
| `agents/` | Claude Code subagents: `infra-engineer`, `infra-reviewer`, `infra-security` |
| `hooks/` | `guard-infra.sh` + plugin `hooks.json`: `PreToolUse` Bash hook: asks before mutating kubectl/helm/terraform/aws commands or reading credential files |
| `config/claude/` | `settings.json` (permissions + hook), `mcp.json` (MCP servers), global `CLAUDE.md` |
| `config/codex/config.toml` | Same MCP servers for Codex CLI |
| `config/kubernetes-mcp-server/config.toml` | Read-only config for `kubernetes-mcp-server` |
| `config/env.example` | Env vars the configs expect |
| `config/AGENTS.example.md` | Example workspace `AGENTS.md` |
| `.claude-plugin/` | Plugin + marketplace manifest: the repo installs as the `devops-skills` plugin |

## Skills

**Read-only advisors** (inspect and write plans, never apply): `audit`, `cost`, `db-review`, `docker-review`, `dr-review`, `incident`, `infra-review`, `k8s-review`, `observability`, `pipeline-review`, `release-readiness`, `runbook`, `security-review`, `terraform-review`.

**Write skills** (confirm before every write): `daily-task` (execute a deploy-request ticket via a k8s-manifest PR), `friday-logwork` (Jira/Tempo worklogs), `confluence-docs` (Confluence pages), `migrate-to-eks`, `migrate-wordpress-to-ec2`.
These were written for one team's setup; adapt the placeholders and names before use.

## Install

```bash
# Claude Code: as a plugin (skills + agents + guard hook; MCP and settings stay manual)
claude plugin marketplace add TonyDo-BBDT/devops-agent-skills
claude plugin install devops-skills@devops-skills

# or copy manually
cp -R skills/* ~/.claude/skills/          # Codex: ~/.codex/skills/
cp agents/*.md ~/.claude/agents/
cp hooks/guard-infra.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/guard-infra.sh
# merge config/claude/settings.json into ~/.claude/settings.json (skip its hooks block if you installed the plugin)
# MCP: merge config/claude/mcp.json into ~/.claude.json (or a project .mcp.json)
#      merge config/codex/config.toml into ~/.codex/config.toml
mkdir -p ~/.config/kubernetes-mcp-server && cp config/kubernetes-mcp-server/config.toml ~/.config/kubernetes-mcp-server/
```

Then export the variables in `config/env.example`. Never commit real values.

## MCP servers

`atlassian`, `github`, `aws-docs`, `eks` (read-only), `aws-cost`, `kubernetes` (read-only), `terraform`, `context7`, `grafana` (`--disable-write`), `sonarqube` (read-only), plus `fetch` for Codex.

## References

- Base skill set: [NotHarshhaa/devops-skills](https://github.com/NotHarshhaa/devops-skills) (MIT, see `LICENSE`)
- [Claude Code skills](https://docs.claude.com/en/docs/claude-code/skills) · [hooks](https://docs.claude.com/en/docs/claude-code/hooks) · [MCP](https://docs.claude.com/en/docs/claude-code/mcp)
- [Codex config](https://github.com/openai/codex/blob/main/docs/config.md)
- [kubernetes-mcp-server](https://github.com/containers/kubernetes-mcp-server) · [mcp-grafana](https://github.com/grafana/mcp-grafana) · [sonarqube-mcp-server](https://github.com/SonarSource/sonarqube-mcp-server) · [awslabs/mcp](https://github.com/awslabs/mcp) · [terraform-mcp-server](https://github.com/hashicorp/terraform-mcp-server)
