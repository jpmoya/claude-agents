# Machine-local pipeline overrides. Copy to ~/.claude/pipeline/config.local.sh (install.sh does this).
# Sourced by ~/.claude/skills/orchestrate/config.sh after the shared defaults. Not tracked; secrets allowed here only.

# Repos this machine may dispatch from the shared `agent-go` pool, as "owner/repo:local-checkout".
# Leave empty on a machine that should only run what you launch by hand.
# Placeholder entries only — this repo is public. Replace with your own repos after install.
DISPATCH_REPOS=(
  "example-owner/project-1:$HOME/dev/project-1"
  "example-owner/project-2:$HOME/dev/project-2"
  "example-owner/project-3:$HOME/dev/project-3"
  "example-owner/project-4:$HOME/dev/project-4"
  "example-owner/project-5:$HOME/dev/project-5"
)

# Concurrent orchestrators this machine runs (default 3 in config.sh).
# MAX_CONCURRENT=3

# Hourly backlog scan (labels new issues agent-proposed, posts a Slack digest). Exactly ONE machine should run it.
# SCAN_BACKLOG=1
# SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."   # secret — this file only, never the repo

# Status board (issue #10): the reporter (skills/orchestrate/report-status.sh) is a silent no-op
# until BOTH are set — leave them commented out on a machine that isn't reporting yet. Set by the
# companion infra issue once the status-page Worker + KV are deployed.
# STATUS_PUSH_URL="https://<worker>.<account>.workers.dev/beat"   # the deployed Worker's /beat endpoint
# STATUS_PUSH_TOKEN="..."                                         # secret — this file only, never the repo

# Repo alias map for the status board (issue #10): "owner/repo:published-alias" — a repo absent
# from this list publishes as "other". Placeholder entries only; this repo is public.
# STATUS_REPO_ALIASES=("example-owner/project-a:project-a" "example-owner/project-b:project-b")
