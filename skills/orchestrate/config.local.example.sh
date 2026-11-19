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
# MAX_CLAUDE_PROCS=10
# ^ ceiling of the orchestrator's pre-dispatch gate — raise it whenever MAX_CONCURRENT is raised (rule in config.sh).

# Hourly backlog scan (labels new issues agent-proposed, posts a Slack digest). Exactly ONE machine should run it.
# SCAN_BACKLOG=1
# SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."   # secret — this file only, never the repo
# Extra repos the scan covers on top of DISPATCH_REPOS — scanned here, never dispatched from this machine.
# SCAN_ONLY_REPOS=("example-owner/project-6")

# Engineering notifications: supervisor.sh notify_engineering() is a silent no-op until BOTH are set.
# SLACK_BOT_TOKEN="..."               # secret (bot token) — this file only, never the repo
# SLACK_ENGINEERING_CHANNEL="C0123456789"   # placeholder channel ID

# Status board (issue #10): the reporter (skills/orchestrate/report-status.sh) is a silent no-op
# until BOTH are set — leave them commented out on a machine that isn't reporting yet. Set by the
# companion infra issue once the status-page Worker + KV are deployed.
# STATUS_PUSH_URL="https://<worker>.<account>.workers.dev/beat"   # the deployed Worker's /beat endpoint
# STATUS_PUSH_TOKEN="..."                                         # secret — this file only, never the repo
# Also reused, unchanged, by skills/orchestrate/push-learnings.sh (message-triage's Learnings tab
# push) — it derives the /learnings/push URL from STATUS_PUSH_URL itself, nothing more to set.

# Repo alias map for the status board (issue #10): "owner/repo:published-alias" — a repo absent
# from this list publishes as "other". Placeholder entries only; this repo is public.
# STATUS_REPO_ALIASES=("example-owner/project-a:project-a" "example-owner/project-b:project-b")

# Delivery-lead Slack DM (issue #117): skills/orchestrate/pm-slack.sh DMs JP only when he must unblock something,
# and the supervisor tick copies his replies onto the issue. A silent no-op until PM_SLACK_BOT_TOKEN is set —
# set it on ONE machine only (the one whose supervisor should poll).
# PM_SLACK_BOT_TOKEN="..."      # secret (bot token: chat:write, im:write, im:history, im:read, reactions:write) — this file only, never the repo
# PM_SLACK_USER_ID="U0123456789"   # placeholder — JP's Slack user id (only this user's DM replies are accepted)

# Mac power (stall fix 2026-10-19): dispatch on battery while charge >= BATTERY_MIN_PCT (default 30; 0 = AC only; ALLOW_BATTERY=1 ignores charge).
# While any run is live the supervisor holds `caffeinate -i` so the lid-open Mac does not idle-sleep; KEEP_AWAKE=0 turns that off.
# BATTERY_MIN_PCT=30

# Scheduled triggers (#769): fire the app repos' schedule-only workflows (scheduled-triggers.conf) from the supervisor tick instead of
# GitHub's unreliable cron. Exactly ONE machine should set this (the VM); the dedupe read also stops a second host double-firing.
# SCHEDULED_TRIGGERS_ENABLED=1

# GitHub webhook events (#773, docs/webhook-events.md): the supervisor reads pushed events instead of polling. Kill switch, default 0 (off:
# polling exactly as before). Secrets are generated on the VM (`openssl rand -hex 32`, one per variable), never committed.
# WEBHOOK_EVENTS_ENABLED=1
# WEBHOOK_SECRET=""          # VM only; secret — the HMAC key shared with the GitHub webhooks (X-Hub-Signature-256)
# WEBHOOK_PULL_TOKEN=""      # VM and Mac; secret — bearer token for GET /events (different value from WEBHOOK_SECRET)
# WEBHOOK_RECEIVER_URL=""    # Mac only: https://<public hostname> of the VM receiver; empty on the VM (it reads its own queue file)
# WEBHOOK_FALLBACK_POLL_MINUTES=20   # full per-repo sync at most this often; heals dropped deliveries
# WEBHOOK_STALE_MINUTES=30           # status banner "no webhook received in N minutes" past this age
