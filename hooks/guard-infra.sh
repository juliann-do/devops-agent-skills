#!/usr/bin/env bash
# PreToolUse guard for the Bash tool.
#
# Two jobs, both of which turn a rule that was previously only written in
# CLAUDE.md / agent prompts into something the harness actually enforces:
#
#   1. Mutating cluster and infra commands must be confirmed by a human.
#      Read-only forms are deliberately let through: --dry-run of any kind,
#      kubectl get/describe/logs/diff, helm template/lint/show, terraform plan.
#   2. Reading credential-shaped files through the shell must be confirmed.
#      The permissions.ask rules cover the Read/Grep/Glob tools; this covers
#      `cat`, `grep`, `base64` and friends, which would otherwise walk straight
#      past those rules.
#
# Emits permissionDecision "ask" so the human decides in-flow. Change to "deny"
# for a hard block that cannot be approved.

set -uo pipefail

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

ask() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

has() { printf '%s' "$cmd" | grep -Eqi "$1"; }

# A dry run mutates nothing, so never gate it.
if has '(^|[[:space:]])--dry-run([=[:space:]]|$)'; then
  DRY=1
else
  DRY=0
fi

# ---------- 1. mutating infra commands ----------
if [ "$DRY" -eq 0 ]; then
  # (.*[[:space:]])? lets global flags sit between the binary and the
  # subcommand (kubectl --context X delete ...) while still matching the bare
  # form (kubectl delete ...).
  if has '(^|[;&|`(]|[[:space:]])kubectl[[:space:]]+(.*[[:space:]])?(apply|create|delete|patch|replace|scale|edit|drain|cordon|uncordon|taint|rollout|annotate|label|set)([[:space:]]|$)'; then
    ask "Blocked: this kubectl command changes live cluster state. Infra changes go through git and ArgoCD, not kubectl. Approve only if you intend to mutate the cluster directly."
  fi
  if has '(^|[;&|`(]|[[:space:]])helm[[:space:]]+(.*[[:space:]])?(install|upgrade|uninstall|delete|rollback)([[:space:]]|$)'; then
    ask "Blocked: this helm command changes live cluster state. Charts are deployed by ArgoCD; only root-app bootstrap is installed by hand."
  fi
  if has '(^|[;&|`(]|[[:space:]])terraform[[:space:]]+(.*[[:space:]])?(apply|destroy|import|taint|untaint)([[:space:]]|$)'; then
    ask "Blocked: this terraform command changes real infrastructure. plan and validate are allowed without confirmation."
  fi
  if has '(^|[;&|`(]|[[:space:]])aws[[:space:]]+[a-z0-9-]+[[:space:]]+(create|delete|update|put|modify|terminate|remove|attach|detach|associate|disassociate|reboot|restore|purchase|cancel|revoke|authorize|enable|disable|register|deregister|tag|untag)-'; then
    ask "Blocked: this AWS CLI command mutates cloud resources. describe/list/get calls are allowed without confirmation."
  fi
  if has '(^|[;&|`(]|[[:space:]])aws[[:space:]]+s3[[:space:]]+(rm|mv|sync|rb)([[:space:]]|$)'; then
    ask "Blocked: this command deletes or overwrites S3 objects."
  fi
fi

# ---------- 2. reading credential-shaped files through the shell ----------
READERS='(cat|bat|less|more|head|tail|grep|egrep|fgrep|rg|ag|awk|sed|strings|xxd|od|base64|jq|yq|cp|scp|rsync|tar|zip|open|code|vim|nano|dotenv|source|\.)'
SECRETS='(\.env($|[^a-zA-Z0-9])|\.env\.[a-zA-Z0-9]|\.enc\.(yaml|yml|json)|/secrets?/|(^|/)secrets?/|\.pem($|[^a-zA-Z0-9])|\.p12($|[^a-zA-Z0-9])|\.pfx($|[^a-zA-Z0-9])|\.key($|[^a-zA-Z0-9])|id_rsa|id_ed25519|id_ecdsa|\.aws/credentials|\.ssh/|\.kube/config|\.netrc|\.npmrc|\.pgpass|credentials\.json|service-account.*\.json)'

if has "(^|[;&|\`(]|[[:space:]])${READERS}[[:space:]]" && has "$SECRETS"; then
  ask "Blocked: this command reads a credential-shaped file (.env, *.enc.yaml, secrets/, *.pem, *.key, SSH or AWS credentials). Approve only if you want its contents in the transcript."
fi

exit 0
