# Machine-local pipeline overrides. Copy to ~/.claude/pipeline/config.local.sh (install.sh does this).
# Sourced by ~/.claude/skills/orchestrate/config.sh after the shared defaults. Not tracked; secrets allowed here only.

# Repos this machine may dispatch from the shared `agent-go` pool, as "owner/repo:local-checkout".
# Leave empty on a machine that should only run what you launch by hand.
DISPATCH_REPOS=(
  "Benjis-Plants/scheduler:$HOME/dev/scheduler"
  "Benjis-Plants/benjis-quoting-tool:$HOME/dev/benjis-quoting-tool"
  "Benjis-Plants/Business-Intelligence:$HOME/dev/Business-Intelligence"
  "jpmoya/casa-verde-site:$HOME/dev/casa-verde-site"
  "jpmoya/Benjis_rfp_finder:$HOME/dev/Benjis_rfp_finder"
)

# Concurrent orchestrators this machine runs (default 3 in config.sh).
# MAX_CONCURRENT=3

# Hourly backlog scan (labels new issues agent-proposed, posts a Slack digest). Exactly ONE machine should run it.
# SCAN_BACKLOG=1
# SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."   # secret — this file only, never the repo
