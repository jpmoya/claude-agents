# status-page

Edge half of the two-host pipeline status board (issue #11, design frozen in #4 §5). A small
Cloudflare Worker: `POST /beat` (authenticated heartbeats), `GET /status.json`, `GET /` (HTML),
`GET /robots.txt`.

No `wrangler` command has been run against this directory as part of building or testing it.
Tests run entirely against the exported `fetch` handler with a hand-written mock KV
(`test/mock-kv.js`) — see `package.json` (vitest only) and `test/*.test.js`.

## What is published (issue #29)

The human-facing routes (`GET /`, `/status.json`, `/pipelines`) now require Google sign-in
against an allowlist (2026-11-05, JP — see "Sign-in" below); `POST /beat`'s own bearer-token
auth is unaffected. Before sign-in was added, the page was public (no auth, `noindex` only). By
JP's decision (2026-09-19) each run's
**issue title and GitHub issue URL are published**. The runs table is
`Issue · Ticket · State · Stage · Marker · Last activity · Restarts`, the Ticket cell links the
title to the issue, and timestamps read like `Sat 19 Sep, 14:05` in Europe/Madrid time
(`/status.json` keeps the raw ISO UTC strings).

- `runs[].title` is the one free-text field that reaches storage: whitespace/control characters
  collapsed, capped at 140 code points, HTML-escaped at render.
- `runs[].url` is kept only if it is exactly `https://github.com/<owner>/<repo>/issues/<n>`;
  `render.js` re-checks it before emitting an `href`.
- Both are optional: a host that sends neither still validates and renders an empty Ticket cell.
- `STATUS_REPO_ALIASES` on the host still populates `runs[].repo` in the payload and
  `/status.json`, but the alias is no longer shown in the HTML table.

### Status groups (issue #62)

The page shows the two host health blocks (name, badge, last seen, capacity), then **one row per
ticket** in seven groups, each an `<h2>` with a count (`Running (4)`). `src/group.js`
(`groupTickets`) is a pure function: tickets are keyed on `url` (else `repo#issue`); among a
ticket's `runs[]` rows across both hosts the latest `last_activity_at` wins (missing loses, tie →
Mac). The first matching rule decides the group:

1. winning run `running` → **Running**
2. key in any `completed[]` (closed within 7 days) → **Done**
3. key in any `approved[]` → **Approved, waiting for a slot**
4. winning run `queued` → **Queued**
5. key in any `staging[]` → **On staging (awaiting production)**
6. winning run `restarting` → **Running** (state cell reads `restarting`)
7. winning run `held` with marker `MOCKUPS PENDING APPROVAL`, `AWAITING GO`,
   `EFFORT APPROVAL NEEDED` or `BLOCKED` → **Needs JP**, unless demoted to **Parked** by any of
   (issue #139):
   - **answered**: host set `parked_reason: "answered"` — a later `**[jp]` or `**[delivery-lead]`
     (legacy: `**[project-manager]`) comment (not a NOTE from the delivery lead) after the gate comment;
   - **out of scope**: host set `parked_reason: "out_of_scope"` — repo not in `DISPATCH_REPOS` ∪
     `SCAN_ONLY_REPOS`;
   - **stale**: `max(gate_at, last_activity_at)` older than 14 days (missing `gate_at` falls back to
     `last_activity_at`; both missing → stays); applied by `group.js`.
   - **auto retry** (issue #250): host set `parked_reason: "auto_retry"` — a `BLOCKED` whose `Blocked on:`
     class is not JP-only (`ci_pending`, `ci_red`, `merge_conflict`, `dependency`, `unsupported_project`,
     `other`); the supervisor re-checks and relaunches it itself. A missing or unparsable class stays Needs JP.
   (A closed or released issue is already **Done**.)

   Before rule 7 (issue #250): a `held` run whose marker is `DEPLOYED`, `DEPLOYED TO STAGING`, `APPLIED` or
   `SPLIT`, or whose key is in any `completed[]` (even past the 7-day Done window), is dropped from Needs JP and
   Parked (Done if still inside the window, else omitted).
8. any other `held` → **Parked** (a `BLOCKED` answered by `DECISION` / `JP CONFIRMED` lands here)

A row demoted by rule 7 is exempt from Parked's 7-day hide; Parked's cap of 10 still applies.

Order: newest first (`last_activity_at`; `updated_at` for Approved / On staging; `closed_at` for
Done; missing last). Caps: Running and Queued uncapped; Approved 20; Needs JP 20 (ages out after 14 days, see rule 7);
On staging 60; Parked 10 and hidden once its last activity is older than 7 days; Done 20 within
7 days. Columns: Running / Queued / Parked `Issue · Ticket · Host · State · Stage ·
Marker · Last activity · Restarts`; Approved / On staging `Issue · Ticket · Updated`; Done
`Issue · Ticket · Closed · Release · Final marker`; Needs JP adds a `Needs` column after Ticket
(`Issue · Ticket · Needs · Host · …`). An empty group reads `(0)` and one `none` row.

Needs JP is grouped by (`repo`, `milestone`) (issue #140), from the optional `runs[].milestone`
key (a non-version GitHub milestone title, ≤ 60 chars matching `^[\w .,()&/+:-]+$`; anything else
is omitted; a missing milestone is **no release**). Groups are ordered by waiting rows (counted
before the cap) descending, ties by repo alias then milestone, "no release" last; rows within a
group newest first; the 20-row cap applies after that ordering. Each group has a header row
`<milestone or no release> (<repo>) — <n> waiting` (n = rows shown after the cap; a group fully
cut by the cap gets none). Other groups are unchanged.

Payload (`v` stays 1, every new key optional; the host half is #65):

- `staging[]` (first 60 valid kept) and `approved[]` (first 20): `{repo, issue, title?, url?,
  updated_at?}`, sanitised by reconstruction (`issue` 1–999999 required else the item is dropped;
  `updated_at` ISO-8601 Z else omitted). Absent or non-array → `[]`.
- `runs[].needs` (one of `Approve mockups`, `Say go`, `Approve effort`, `Missing credential`,
  `Decision needed`; `BLOCKED` → `Missing credential` when its `Blocked on:` line matches
  `credential|token|secret|api key|password|access`), `runs[].gate_at` (ISO-8601 Z) and
  `runs[].parked_reason` (`answered` | `out_of_scope` | `auto_retry`) and `runs[].block_class` (fixed class, shown on
  Parked rows as `CI/billing`, `merge conflict`, `waiting on dependency` or `other` in the Marker cell): all optional, unknown values dropped, no
  comment text is ever published. An old payload without them renders an empty `Needs` cell.
- `completed[].release`, kept only if it matches `^v\d+\.\d+\.\d+$`.
- `DECISION` and `JP CONFIRMED` are known markers.
- The beat body cap is **128 KB** (`131072` bytes → `204`, one more → `413`).

Host half (issue #65): `reconcile-status.sh` also fetches, for every repo in `DISPATCH_REPOS` ∪
`SCAN_ONLY_REPOS` (each once), the open issues with milestone `staging` and the open `agent-go`
issues, writes them to `$PIPE/status-staging.json` / `status-approved.json` (a failed call keeps
that repo's previous entries) and the network-free builder publishes them as `staging[]` and
`approved[]` (newest `updated_at` first, caps 60 / 20, title ≤ 140 chars). A ticket whose GitHub
milestone is a release (`vX.Y.Z`) counts as released even while its issue is still open: the host
treats it like a closed one (Done, with `completed[].release`). `runs[]` priority is
running, restarting, queued, held (newest activity first within a state), total cap 20; a non-running row
whose ticket is in the host's staging list is left out.

Completed-ticket source (issue #51):

- The host half is `skills/orchestrate/reconcile-status.sh`: a reconcile pass, run from the
  supervisor tick at most once per 600 s per host, that asks GitHub for each listed ticket's state,
  close time and latest routing marker and records them in local files. The reporter only reads
  those files (no network call).
- `completed[]` items are `{repo, issue, closed_at, title?, url?, marker?}`, sanitised by
  reconstruction like `runs[]` (`issue` 1–999999 and an ISO-8601 Z `closed_at` are required, more
  than 10 items keep the first 10, a non-array becomes `[]`). Payload `v` stays 1: an older Worker
  drops the key, a newer Worker renders a payload without it as an empty Done group.

## Backlog priority (reorder view)

JP's priority order for standalone (non-goal) open `agent-go` tickets across both hosts'
`DISPATCH_REPOS` ∪ `SCAN_ONLY_REPOS`. It only ever reorders standalone tickets among themselves —
the goals-first-then-fill-with-standalone-tickets dispatch logic, `MAX_CONCURRENT` and
`GOAL_SERIAL` are untouched, and a ticket carrying a `goal: <title>` label (goal-lib.sh's
`goal_label_name`) is never reordered by this feature.

- **Store.** `$PIPE/backlog-priority.json` on each host, `{"owner/repo#issue": <0-based rank>}`
  (lower rank = dispatched first). Source of truth is a single machine-managed GitHub issue (label
  `backlog-priority-registry`, body = a JSON array of keys in order) in `$GOAL_REGISTRY_REPO` —
  same pattern as the goal registry (goal-lib.sh: "A goal is a registry issue on GitHub ...;
  `$PIPE/goal-<id>.*` is only a host-local cache"). `skills/orchestrate/backlog-priority.sh pull`
  refreshes the cache (called from `reconcile-status.sh`'s pass, throttled the same way);
  `backlog-priority.sh set <owner/repo#issue>...` writes a new full order (registry issue, then
  the local cache) — this is the command the status page prints for JP to edit and run by hand.
- **Dispatch side** (`supervisor.sh`'s shared-dispatch step, around "5. Shared dispatch"): the
  per-repo candidate list is sorted today's way (milestone `vX.Y.Z` asc, then issue asc), then
  `skills/orchestrate/lib/backlog-sort.jq` reorders only the non-goal slots by stored rank
  (ranked first, lowest rank first; unranked after, in today's order) — a goal-labelled ticket's
  position in that sorted list is never touched. A missing or corrupt store (bad JSON, no entries
  for the repo) falls back to `{}`: dispatch for that repo is never aborted by it.
- **Display side.** `reconcile-status.sh` also refreshes `$PIPE/status-backlog.json` — open
  `agent-go` issues, minus anything carrying `agent-in-progress` or a `goal: ` label, for every
  repo in `DISPATCH_REPOS` ∪ `SCAN_ONLY_REPOS`. The network-free builder (`build-runs-json.py
  backlog`) turns that plus the local priority cache into the payload's `backlog[]`: `{repo, issue,
  title?, url?, rank?}` (cap 100; `rank` omitted when the ticket is untracked), ordered the same
  way as the dispatch side. The page merges both hosts' `backlog[]` by key (a repo in both hosts'
  scope can publish the same ticket twice) and renders a numbered table where each row is a native
  HTML5 drag source: drag a row by its handle to reorder it live in the table, or focus the handle
  (Tab) and press Arrow Up/Down to move it without a mouse. Either path POSTs the new order
  straight to `POST /backlog-priority` (same Google-SSO gate as every other human-facing route),
  which writes the registry issue via the GitHub REST API (`src/backlog-priority.js` — the Worker
  can't shell out to `gh`, so this is a second writer of the same issue `backlog-priority.sh`'s
  `set` writes, never a new primitive) and reloads the page on success. This needs the
  `GITHUB_TOKEN` secret (below); without it the drag/keyboard controls still render but a save
  503s. "Approved, waiting for a slot" excludes any ticket already shown here (see `group.js`'s
  dedup) so a standalone ticket never renders twice on the page.

## Infra hand-off contract (companion `infra` issue's job, not this one's)

1. Create a KV namespace and bind it as `STATUS` in `wrangler.jsonc`, replacing the placeholder
   `id`.
2. `wrangler secret put TOKEN_MAC` and `wrangler secret put TOKEN_VM` — one bearer token per
   host. Never pass these as CLI arguments or echo them; use the interactive prompt.
3. `wrangler deploy` to the free `*.workers.dev` subdomain (no custom domain, no paid plan) — a
   one-time manual deploy to get the Worker to exist. After that, `.github/workflows/deploy-status-page.yml`
   redeploys automatically on every push to `main` that touches `status-page/`, using a
   `CLOUDFLARE_API_TOKEN` repo secret scoped to Account → Workers Scripts:Edit and Workers KV
   Storage:Edit only (JP, 2026-10-27 — a merged change had sat undeployed for hours because nobody
   remembered the manual step).
4. Put the deployed URL in each host's `config.local.sh` as `STATUS_PUSH_URL`, and the matching
   token as `STATUS_PUSH_TOKEN` (host-side reporter, issue #10).

## Sign-in (Google OAuth, 2026-11-05)

`GET /`, `GET /status.json` and `GET /pipelines` require a signed-in, allowlisted Google
account. `POST /beat` (the pipeline hosts' heartbeat) is untouched — still bearer-token auth,
never a cookie.

**How it works** (`src/auth.js`, wired into `src/index.js`): a standard OAuth 2.0 Authorization
Code flow, no library. An unauthenticated GET on a protected route redirects (302) to `/login`,
which sets a short-lived, signed `oauth_state` cookie and redirects to Google. Google redirects
back to `/auth/callback?code=...&state=...`; the Worker checks `state` against the cookie
(CSRF), exchanges `code` for a token at Google's token endpoint, reads the signed-in email from
Google's userinfo endpoint, and — only if `email_verified` is true and the email (lowercased,
trimmed) is in the `ALLOWED_EMAILS` secret — issues a signed session cookie
(`email|expiresAtEpochSecs|hmacSha256Hex`, 30-day expiry, HttpOnly/Secure/SameSite=Lax) and
redirects to `/`. The allowlist is re-checked on every request, so removing an email from
`ALLOWED_EMAILS` revokes an already-issued cookie immediately, without rotating `SESSION_SECRET`.
Adding a second viewer is a one-line `ALLOWED_EMAILS` edit — no code change.

**This repo cannot create the Google OAuth client** — that needs JP's own GCP Console access.
Everything below is a one-time setup JP (or whoever JP delegates) does once this PR is open (the
redirect URI must exist before testing sign-in; the secrets must exist before this merges — see
the deploy note at the end):

1. **Create the OAuth client** — Google Cloud Console → APIs & Services → Credentials → Create
   Credentials → OAuth client ID → Application type **Web application**.
   - **Authorized redirect URI** (exact match, no trailing slash):
     `https://pipeline-status-jp.vercel.app/auth/callback` — the Vercel front in
     `vercel-proxy/`, which is the URL humans open and the Worker's `PUBLIC_ORIGIN`
     (`wrangler.jsonc`). The Worker's own `https://status-page.jpmoya.workers.dev/auth/callback`
     is registered too, but JP's ISP blocks the IPs `workers.dev` resolves to, so sign-in
     always returns to the Vercel host (2026-11-08, #614). Both are on the client now.
   - If prompted to configure the **OAuth consent screen** first: User type **External**,
     publish it to **Production** (not "Testing" — Testing restricts sign-in to a hand-picked
     test-user list, which defeats "adding a second viewer is a one-line secret change"). Scopes
     are just `openid` and `email` (also `.../auth/userinfo.email`) — at the time of writing
     that scope tier does not require Google's app-verification review, but re-check this against
     Google's current verification rules before publishing, since Google's policy here has
     changed before.
2. Copy the **Client ID** and **Client secret** Google shows you.
3. Set four Worker secrets from this directory (never paste values as CLI arguments — use the
   interactive prompt each `wrangler secret put` opens):
   ```
   wrangler secret put GOOGLE_CLIENT_ID
   wrangler secret put GOOGLE_CLIENT_SECRET
   wrangler secret put SESSION_SECRET      # any long random string, e.g. `openssl rand -hex 32`
   wrangler secret put ALLOWED_EMAILS      # start with just your own address
   ```
   `ALLOWED_EMAILS` is comma-separated (`you@example.com, someone-else@example.com`) — case and
   surrounding whitespace don't matter, both are normalised on every check.
4. **Set the secrets before merging this PR to `main`.** The Worker currently redeploys
   automatically on every push to `main` via Cloudflare's own Workers Builds git integration (not
   a GitHub Actions workflow — see the note at the end of "Infra hand-off contract" above, which
   still describes the older GitHub Actions deploy and is stale as of #528). Secrets persist
   independently of a deploy, so setting them first means the human-facing routes work the moment
   this merges; merging first would lock out `/`, `/status.json` and `/pipelines` (not `/beat`)
   until the secrets are set.
5. Sign in once at `https://pipeline-status-jp.vercel.app/login` to confirm the redirect URI and
   the allowlist are both right.

A misconfigured or not-yet-set `GOOGLE_CLIENT_ID`/`SESSION_SECRET` makes `/login` and
`/auth/callback` fail closed with `503` rather than redirect with an empty `client_id`.

## Backlog reorder write path (`GITHUB_TOKEN` secret, needed for drag-and-drop reorder)

`POST /backlog-priority` (behind the same session-cookie gate as `/`, `/pipelines`,
`/status.json`) needs a GitHub token with permission to read and write issues on
`jpmoya/claude-agents` (the registry repo `backlog-priority.sh` also writes to). **JP needs to
set this — this PR does not and cannot create or see the token value:**

1. Create a fine-grained personal access token (GitHub → Settings → Developer settings →
   Personal access tokens → Fine-grained tokens) scoped to **only** the `jpmoya/claude-agents`
   repository, with repository permission **Issues: Read and write** and nothing else.
2. From this directory:
   ```
   wrangler secret put GITHUB_TOKEN
   ```
   (never paste the token as a CLI argument — use the interactive prompt).

Without this secret, the drag/keyboard reorder controls still render but a save fails with `503`
(JP falls back to the terminal `backlog-priority.sh set` command); nothing else on the page is
affected.

## Learnings tab

JP's personal `message-triage` agent (`~/.claude/agents/message-triage.md`, outside this repo)
keeps an append-only, plain-markdown bullet log of lessons learned from his edits
(`~/.claude/agents/message-triage-learnings.md`). This tab shows that log and lets JP edit or
delete entries from the browser — the status page's first non-pipeline data source.

The Worker can't reach JP's Mac filesystem, so this is a one-way sync, same shape as the
`POST /beat` heartbeat: `skills/orchestrate/push-learnings.sh` (called by `message-triage.md`
after it appends a new learning) POSTs the file's raw content to `POST /learnings/push`, bearer-
auth'd with the same `TOKEN_MAC`/`TOKEN_VM` secrets and rate limiter as `/beat` — a separate
secret would buy no real isolation (same Mac, same user, same readable config) and would mean one
more `wrangler secret put` to forget before this works. The Worker parses bullet lines
(`src/learnings.js`'s `parseLearningsMarkdown`) and merges them into KV key `learnings:entries`:
`{ entries: [{id, text, added_at}], seen: string[] }`. A line's exact text is added at most once
(tracked in `seen`, kept forever, even past an edit or delete) — that's what makes re-running the
push against the same, ever-growing append-only file safe: it can never re-add, or resurrect, a
line already seen.

`GET /learnings` (same Google-session-cookie gate as `/`, `/pipelines`) renders the `entries` list
with a "Learnings" nav link alongside "Status" | "Pipelines"; each row is two plain HTML forms, no
JS — a textarea + Save posting to `POST /learnings/edit`, and a Delete button posting to
`POST /learnings/delete` (same session gate, 303 back to `/learnings`, 404 for an unknown id).
Both are display-only: they change what KV (and so the page) shows, never the Mac file, and never
touch `seen`, so the next push can't undo a delete or duplicate an edit. **This means deleting a
lesson here does not stop `message-triage` from applying it** — the agent still reads its own
file. Treat the page as a view/cleanup layer on top of the real log, not a way to retract a
lesson; edit the Mac file by hand (or change the agent's own editing habits) for that.
No new Worker secret or KV namespace: `/learnings/push` reuses `TOKEN_MAC`/`TOKEN_VM`, and
`learnings:entries` lives in the existing `STATUS` namespace.

## Pipelines tab (issue #273)

`GET /pipelines` is a static, server-rendered routing diagram (no JS, no KV access) with a
"Status" | "Pipelines" nav on both pages. Data lives in `src/pipelines.js`; a condition with
`coming: true` renders a "coming" chip — flip the flag when the rule lands. The pipelines vitest
file fails if a stage name or condition drifts from `agents/*.md`. Render errors return 500 and call
`captureError` (release/environment/route tags; Slack via `SLACK_WEBHOOK_URL`, a no-op when unset).
