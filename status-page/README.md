# status-page

Edge half of the two-host pipeline status board (issue #11, design frozen in #4 §5). A small
Cloudflare Worker: `POST /beat` (authenticated heartbeats), `GET /status.json`, `GET /` (HTML),
`GET /robots.txt`.

No `wrangler` command has been run against this directory as part of building or testing it.
Tests run entirely against the exported `fetch` handler with a hand-written mock KV
(`test/mock-kv.js`) — see `package.json` (vitest only) and `test/*.test.js`.

## What is published (issue #29)

The page is public (no auth, `noindex` only). By JP's decision (2026-09-19) each run's
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
   `EFFORT APPROVAL NEEDED` or `BLOCKED` → **Needs JP**
8. any other `held` → **Parked** (a `BLOCKED` answered by `DECISION` / `JP CONFIRMED` lands here)

Order: newest first (`last_activity_at`; `updated_at` for Approved / On staging; `closed_at` for
Done; missing last). Caps: Running and Queued uncapped; Approved 20; Needs JP 20 (never aged out);
On staging 60; Parked 10 and hidden once its last activity is older than 7 days; Done 20 within
7 days. Columns: Running / Queued / Needs JP / Parked `Issue · Ticket · Host · State · Stage ·
Marker · Last activity · Restarts`; Approved / On staging `Issue · Ticket · Updated`; Done
`Issue · Ticket · Closed · Release · Final marker`. An empty group reads `(0)` and one `none` row.

Payload (`v` stays 1, every new key optional; the host half is #65):

- `staging[]` (first 60 valid kept) and `approved[]` (first 20): `{repo, issue, title?, url?,
  updated_at?}`, sanitised by reconstruction (`issue` 1–999999 required else the item is dropped;
  `updated_at` ISO-8601 Z else omitted). Absent or non-array → `[]`.
- `completed[].release`, kept only if it matches `^v\d+\.\d+\.\d+$`.
- `DECISION` and `JP CONFIRMED` are known markers.
- The beat body cap is **128 KB** (`131072` bytes → `204`, one more → `413`).

Completed-ticket source (issue #51):

- The host half is `skills/orchestrate/reconcile-status.sh`: a reconcile pass, run from the
  supervisor tick at most once per 600 s per host, that asks GitHub for each listed ticket's state,
  close time and latest routing marker and records them in local files. The reporter only reads
  those files (no network call).
- `completed[]` items are `{repo, issue, closed_at, title?, url?, marker?}`, sanitised by
  reconstruction like `runs[]` (`issue` 1–999999 and an ISO-8601 Z `closed_at` are required, more
  than 10 items keep the first 10, a non-array becomes `[]`). Payload `v` stays 1: an older Worker
  drops the key, a newer Worker renders a payload without it as an empty Done group.

## Infra hand-off contract (companion `infra` issue's job, not this one's)

1. Create a KV namespace and bind it as `STATUS` in `wrangler.jsonc`, replacing the placeholder
   `id`.
2. `wrangler secret put TOKEN_MAC` and `wrangler secret put TOKEN_VM` — one bearer token per
   host. Never pass these as CLI arguments or echo them; use the interactive prompt.
3. `wrangler deploy` to the free `*.workers.dev` subdomain (no custom domain, no paid plan).
4. Put the deployed URL in each host's `config.local.sh` as `STATUS_PUSH_URL`, and the matching
   token as `STATUS_PUSH_TOKEN` (host-side reporter, issue #10).
