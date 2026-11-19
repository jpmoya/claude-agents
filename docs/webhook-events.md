# GitHub webhook events for the supervisor (#773)

The supervisor used to learn what changed on GitHub only by polling, which drains the shared 5,000/hour API budget. GitHub webhook
deliveries do not count against that budget, so the VM receives them and the supervisors read a local queue instead.

```
GitHub --HTTPS--> Caddy (VM, :443) --http--> webhook-receiver.py (127.0.0.1:8787) --> $PIPE/webhook/events.jsonl
                                                                                         |  (VM supervisor reads the file)
Mac supervisor --HTTPS, bearer token--> GET /events?since=<seq> --> $PIPE/webhook/events.jsonl (mirror)
```

Kill switch: `WEBHOOK_EVENTS_ENABLED` (default `0`). Off means the supervisor polls exactly as before, the receiver launcher refuses
to start and no status banner is published. Setting it back to `0` returns to full polling on the next tick, nothing else restarts.

## What it does when on

- `webhook_tick_prepare` (webhook-events.sh, called once per supervisor tick before the sync loop) pulls from the VM (Mac only), then
  applies every queued event since its cursor to the read cache: the touched issue / PR entry and the repo's list entries are dropped.
- `gh_since_sync <repo>` then makes **no API call** for a repo whose fallback poll is not due. Reads of unchanged tickets keep being
  served from the cache (the #637 mechanism); only touched objects are re-read.
- Fallback poll: each repo still runs the existing full `issues?since=` sync every `WEBHOOK_FALLBACK_POLL_MINUTES` (default 20).
  Only that sync advances the since cursor, so its window covers any delivery that was dropped. A reset or compacted queue
  (`gap`) forces a full sync for every repo on the next call.
- Other processes (goal sync, reconcile-status) trust the same cached single-issue / issues-list reads without a wall-clock expiry
  while the supervisor's last apply is under `WEBHOOK_TRUST_SECS` (600) old and the repo's fallback poll is not overdue.
- Only repos whose owner is in `WEBHOOK_OWNERS` (default `Benjis-Plants`, the owners that have a hook) are served from events; a repo of
  any other owner keeps the plain per-tick since-sync.
- Status page banner: while on, if the newest event (or, for an empty queue, the time the switch was turned on) is older than
  `WEBHOOK_STALE_MINUTES` (30), the host publishes `webhook_stale: {since}` and the page shows "no webhook received in N minutes".
  Quiet hours with no GitHub activity at all will also raise it (amber, informational: the fallback poll keeps working).

Not covered yet (follow-up): issue/PR GraphQL reads (`gh issue list`, `gh pr list`, `gh repo view`) and the goal-project GraphQL
reads still use their own TTLs; they are the bulk of the remaining idle calls.

## Receiver security

- `X-Hub-Signature-256` (`sha256=` + HMAC-SHA256 of the raw body) is checked with a constant-time compare before any parsing. Missing,
  malformed, `sha1=` or wrong: 401, nothing queued.
- Order of checks: method/path allow-list (404/405), per-source rate limit (429, default 120/min), `Content-Length` required (411) and
  at most 1 MiB (413) decided before the body is read, signature, JSON, event allow-list, delivery-id dedupe.
- `X-GitHub-Delivery` ids are kept for 24 h in `seen-deliveries` (survives restarts); a replay returns 200 and is not queued again.
- Only POST `/webhook`, GET `/events` (bearer `WEBHOOK_PULL_TOKEN`, constant-time compare), GET `/health`.
- The queue holds only validated tags (event, action, `owner/repo`, number, sender login, delivery id, time). No payload text. Every
  consumer reads it with `jq`; nothing is `eval`'d or expanded unquoted.
- The secrets are read from the environment (exported by `webhook-receiver.sh` from `config.local.sh`), never argv, never logged.
  The receiver refuses to start without both (16+ chars, different values). Errors raise one Slack post per 10 minutes through the
  existing `SLACK_WEBHOOK_URL`, tagged `release=<sha> environment=<host> route=webhook-receiver` and carrying no message text.
- Behind Caddy the peer is always 127.0.0.1, so the rate limit keys on the right-most `X-Forwarded-For` (Caddy overwrites a client's
  value) and only trusts it from `WEBHOOK_TRUSTED_PROXIES` (default loopback). GitHub does not redeliver by itself: a delivery that
  got a 429/5xx is covered by the fallback poll, or redeliver it from the hook's Recent Deliveries page.

## Go-live runbook (VM unless said otherwise)

Choices: **TLS = Caddy with automatic certificates** (rejected: a Cloudflare tunnel needs another account and moving part; exposing the
Python server directly has no TLS). **Hostname = `hooks.moyadigital.com`** (default from the ticket). **Port**: only 80 and 443 open
inbound (80 is needed for the ACME challenge); the receiver stays on 127.0.0.1:8787.

1. DNS (JP-only, external system): A record `hooks.moyadigital.com` -> the VM's public IP.
2. Secrets on the VM, written without printing them:
   ```bash
   umask 077
   printf 'WEBHOOK_SECRET="%s"\nWEBHOOK_PULL_TOKEN="%s"\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" >> ~/.claude/pipeline/config.local.sh
   ```
   Copy only `WEBHOOK_PULL_TOKEN` to the Mac's `config.local.sh`, together with `WEBHOOK_RECEIVER_URL="https://hooks.moyadigital.com"`.
   Leave `WEBHOOK_EVENTS_ENABLED` unset for now.
3. Install Caddy (`apt install caddy`), then:
   ```bash
   sed 's/hooks.example.com/hooks.moyadigital.com/' infra/webhook/Caddyfile | sudo tee /etc/caddy/Caddyfile >/dev/null
   sudo mkdir -p /var/log/caddy && sudo chown caddy /var/log/caddy
   sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy   # the log `format filter` syntax varies by Caddy version
   sudo ufw allow 80,443/tcp   # or the VM provider's firewall; do NOT open 8787
   ```
4. systemd unit (set the account and checkout path):
   ```bash
   sed -e "s#@VM_USER@#$USER#g" -e "s#@REPO_DIR@#$HOME/dev/claude-agents#" -e "s#@STATE_DIR@#$HOME/.claude/pipeline/state#" infra/webhook/webhook-receiver.service | sudo tee /etc/systemd/system/webhook-receiver.service >/dev/null
   sudo systemctl daemon-reload
   ```
   The unit exits quietly while the kill switch is off. Turn the switch on for the VM (`WEBHOOK_EVENTS_ENABLED=1` in
   `config.local.sh`), then `sudo systemctl enable --now webhook-receiver` and check `curl -s https://hooks.moyadigital.com/health`
   returns `{"ok":true}` and `curl -s -o /dev/null -w '%{http_code}' https://hooks.moyadigital.com/events` returns 401.
5. Create the webhooks only now (needs a token with `admin:org_hook`: `gh auth refresh -h github.com -s admin:org_hook`). The secret is
   piped to `gh` on stdin so it never appears in argv or shell history; run on the VM (it has the secret):
   ```bash
   . ~/.claude/pipeline/config.local.sh
   EV='"issues","issue_comment","pull_request","check_run","check_suite","workflow_run"'
   jq -n --arg secret "$WEBHOOK_SECRET" --arg url "https://hooks.moyadigital.com/webhook" "{name:\"web\",active:true,events:[$EV,\"projects_v2_item\"],config:{url:\$url,content_type:\"json\",secret:\$secret,insecure_ssl:\"0\"}}" \
     | gh api -X POST orgs/Benjis-Plants/hooks --input - --jq '.id'
   jq -n --arg secret "$WEBHOOK_SECRET" --arg url "https://hooks.moyadigital.com/webhook" "{name:\"web\",active:true,events:[$EV],config:{url:\$url,content_type:\"json\",secret:\$secret,insecure_ssl:\"0\"}}" \
     | gh api -X POST repos/jpmoya/claude-agents/hooks --input - --jq '.id'
   ```
   `projects_v2_item` is an organization-level event, so it is left off the user-owned repo's hook. Record both ids in the PR.
   Verify each: `gh api -X POST orgs/Benjis-Plants/hooks/<id>/pings` then `gh api orgs/Benjis-Plants/hooks/<id>/deliveries --jq '.[0].status_code'` (expect 200).
6. Mac: set `WEBHOOK_EVENTS_ENABLED=1` in its `config.local.sh`. The next tick pulls and applies events.
7. Check: `tail ~/logs/pipeline/supervisor.log | grep '\[webhook\]'` shows `applied events=N gap=0`; the status page shows no webhook banner.

Roll back at any time with `WEBHOOK_EVENTS_ENABLED=0` on either host (the VM's receiver then stops being restarted; `systemctl stop
webhook-receiver` to stop it now). Delete the hooks with `gh api -X DELETE orgs/Benjis-Plants/hooks/<id>`.

## Measuring the call reduction

Per-tick GitHub calls from the call log (idle ticks only, same host, before vs after the switch):
```bash
awk '$4=="call"{n++} END{print n}' ~/logs/pipeline/gh-calls.log   # total calls in the window
grep -c 'gh-quota remaining' ~/logs/pipeline/supervisor.log        # ticks in the same window (one quota line per tick)
```
Divide the first by the second over at least 30 idle ticks, before and after.
