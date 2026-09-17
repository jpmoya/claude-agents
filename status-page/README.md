# status-page

Edge half of the two-host pipeline status board (issue #11, design frozen in #4 §5). A small
Cloudflare Worker: `POST /beat` (authenticated heartbeats), `GET /status.json`, `GET /` (HTML),
`GET /robots.txt`.

No `wrangler` command has been run against this directory as part of building or testing it.
Tests run entirely against the exported `fetch` handler with a hand-written mock KV
(`test/mock-kv.js`) — see `package.json` (vitest only) and `test/*.test.js`.

## Infra hand-off contract (companion `infra` issue's job, not this one's)

1. Create a KV namespace and bind it as `STATUS` in `wrangler.jsonc`, replacing the placeholder
   `id`.
2. `wrangler secret put TOKEN_MAC` and `wrangler secret put TOKEN_VM` — one bearer token per
   host. Never pass these as CLI arguments or echo them; use the interactive prompt.
3. `wrangler deploy` to the free `*.workers.dev` subdomain (no custom domain, no paid plan).
4. Put the deployed URL in each host's `config.local.sh` as `STATUS_PUSH_URL`, and the matching
   token as `STATUS_PUSH_TOKEN` (host-side reporter, issue #10).
