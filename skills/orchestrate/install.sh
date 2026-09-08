#!/usr/bin/env bash
# Set up (or re-check) this machine for the agent pipeline. Idempotent — safe to re-run after every pull.
#   ~/.claude/skills/orchestrate/install.sh --minute even|odd [--repos-base DIR] [--scan]
#   --minute      supervisor cron phase; give each machine a different one (VM=even, Mac=odd) so ticks interleave
#   --repos-base  where the repo checkouts live when creating config.local.sh (default: ~/dev, or ~ if ~/dev is absent)
#   --scan        this machine runs the hourly backlog scan (exactly one machine should)
set -uo pipefail
MINUTE=""; BASE=""; SCAN=0
while [ $# -gt 0 ]; do case "$1" in
  --minute) MINUTE="$2"; shift 2;; --repos-base) BASE="$2"; shift 2;; --scan) SCAN=1; shift;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; done
[ "$MINUTE" = even ] || [ "$MINUTE" = odd ] || { echo "--minute even|odd required" >&2; exit 2; }

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"      # the claude-agents checkout
CL="$HOME/.claude"; PIPE_CFG="$CL/pipeline"; LOGS="$HOME/logs/pipeline"
ok()   { printf '  ok   %s\n' "$*"; }
todo() { printf '  TODO %s\n' "$*"; TODOS=$((TODOS+1)); }
TODOS=0

echo "1. symlinks (~/.claude/* -> $REPO_DIR)"
mkdir -p "$CL"
for i in agents hooks skills CLAUDE.md settings.json; do
  if [ -L "$CL/$i" ] && [ "$(readlink "$CL/$i")" = "$REPO_DIR/$i" ]; then ok "$i"
  elif [ -e "$CL/$i" ]; then mkdir -p "$CL/backups/pre-install"; mv "$CL/$i" "$CL/backups/pre-install/$i.$(date +%s)"; ln -s "$REPO_DIR/$i" "$CL/$i"; ok "$i (replaced; old copy in ~/.claude/backups/pre-install)"
  else ln -s "$REPO_DIR/$i" "$CL/$i"; ok "$i (linked)"; fi
done

echo "2. per-machine config"
mkdir -p "$PIPE_CFG" "$LOGS" /tmp/pipeline/queue
if [ -f "$PIPE_CFG/config.local.sh" ]; then ok "config.local.sh exists (not touched)"
else
  [ -n "$BASE" ] || { [ -d "$HOME/dev" ] && BASE="$HOME/dev" || BASE="$HOME"; }
  sed "s|\$HOME/dev/|$BASE/|g" "$REPO_DIR/skills/orchestrate/config.local.example.sh" > "$PIPE_CFG/config.local.sh"
  [ "$SCAN" = 1 ] && sed -i.bak 's|^# SCAN_BACKLOG=1|SCAN_BACKLOG=1|' "$PIPE_CFG/config.local.sh" && rm -f "$PIPE_CFG/config.local.sh.bak"
  ok "config.local.sh created from the example with repos under $BASE — edit DISPATCH_REPOS to what this machine should run"
fi
# drop DISPATCH_REPOS entries whose checkout is missing, warn
source "$REPO_DIR/skills/orchestrate/config.sh"
for e in "${DISPATCH_REPOS[@]}"; do [ -d "${e#*:}" ] || todo "checkout missing for ${e%%:*} at ${e#*:} — clone it or remove the entry from config.local.sh"; done
if [ "$SCAN" = 1 ] && [ -z "${SLACK_WEBHOOK_URL:-}" ]; then todo "SCAN enabled but SLACK_WEBHOOK_URL unset in config.local.sh (scan still labels, just no Slack post)"; fi

echo "3. repo trust (headless runs ignore permissions.allow in untrusted checkouts)"
python3 - "$HOME/.claude.json" "${DISPATCH_REPOS[@]}" <<'PY'
import json,sys,os
p=sys.argv[1]; d=json.load(open(p)) if os.path.exists(p) else {}
pr=d.setdefault('projects',{}); changed=[]
for e in sys.argv[2:]:
    path=e.split(':',1)[1]
    if os.path.isdir(path) and not pr.get(path,{}).get('hasTrustDialogAccepted'):
        pr.setdefault(path,{})['hasTrustDialogAccepted']=True; changed.append(path)
if changed: json.dump(d,open(p,'w'),indent=2)
print('  ok   trusted: '+(', '.join(changed) if changed else 'nothing new'))
PY

echo "4. cron"
[ "$MINUTE" = even ] && M='*/2' || M='1-59/2'
SUP="$M * * * * $CL/skills/orchestrate/supervisor.sh >> $LOGS/supervisor.log 2>&1"
SCN="0 * * * * $CL/skills/orchestrate/scan-backlog.sh >> $LOGS/scan.log 2>&1"
cur=$(crontab -l 2>/dev/null || true)
new=$(printf '%s\n' "$cur" | grep -v -E 'orchestrate/supervisor\.sh|scan-backlog\.sh|pipeline/dispatch\.sh')
new="$new"$'\n'"# Agent pipeline supervisor (installed by claude-agents install.sh)"$'\n'"$SUP"
[ "$SCAN" = 1 ] && new="$new"$'\n'"# Agent pipeline hourly backlog scan"$'\n'"$SCN"
if [ "$(printf '%s\n' "$cur" | grep -c -F "$SUP")" = 1 ] && { [ "$SCAN" = 0 ] || [ "$(printf '%s\n' "$cur" | grep -c -F "$SCN")" = 1 ]; } && ! printf '%s\n' "$cur" | grep -q 'pipeline/dispatch\.sh'; then ok "crontab already correct"
else printf '%s\n' "$new" | sed '/^$/N;/^\n$/D' | crontab - && ok "crontab updated: supervisor on $MINUTE minutes$([ "$SCAN" = 1 ] && echo ', hourly scan')"; fi

echo "5. tools"
for t in gh jq git claude; do command -v "$t" >/dev/null && ok "$t" || todo "$t not on PATH"; done
gh auth status >/dev/null 2>&1 && ok "gh logged in" || todo "gh auth login"
command -v vercel >/dev/null && { vercel whoami >/dev/null 2>&1 && ok "vercel logged in" || todo "vercel login (infra track)"; } || todo "vercel CLI missing (infra track only)"
command -v flock >/dev/null || ok "no flock — supervisor uses its mkdir lock (macOS)"
[ -f "$CL/settings.local.json" ] && ok "settings.local.json present" || todo "create ~/.claude/settings.local.json (model, theme; env block for SUPABASE_MGMT_PAT etc. — see README)"

echo; [ "$TODOS" = 0 ] && echo "Ready." || echo "$TODOS item(s) need you (marked TODO)."
