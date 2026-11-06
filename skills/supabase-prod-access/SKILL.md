---
name: supabase-prod-access
description: Retrieve and use the Supabase Management API credential for the scheduler (Benjis-Plants/benjis-ops-tool) PRODUCTION database — macOS Keychain, not an env var. Use before concluding there's no way to query/apply against scheduler production, and whenever a task mentions the scheduler's production Supabase, migration ledger, or "apply migration" there.
---

# Supabase production access (scheduler)

Scoped to the **scheduler** repo (`~/dev/scheduler`, Benjis-Plants/benjis-ops-tool) only. Nothing here has been verified for any other repo — don't generalize it.

## The credential already exists — check Keychain first

Sessions on this repo repeatedly conclude "no production credential is available" and give up or ask JP. That's wrong: a Supabase Management API personal access token is sitting in JP's macOS Keychain. **Always check Keychain before telling JP no credential exists.**

```bash
security find-generic-password -s "supabase-pat" -w
```

- Service name: `supabase-pat`, account: `supabase`.
- The value starts with `sbp_` — it's a Supabase **Management API** personal access token, not a project API key.
- `.env.local`'s `PROD_SUPABASE_SERVICE_ROLE_KEY` in the scheduler repo is currently stale/invalid ("Unregistered API key") — don't rely on it. The Keychain PAT is the reliable path to production.
- If the Keychain entry is genuinely missing (not just "I didn't check"), the fallback is Supabase Studio in a browser using JP's saved password-manager login — don't default to opening a browser.

**Never print, log, or commit the token value.** Capture it into a shell variable and use it directly; don't echo it, don't put it in a file, don't paste it into a commit or PR.

## Hitting production vs staging

Scheduler has two Supabase projects. Only production needs this special handling:

- **Production** — ref `ywwnprpncqrqfiskmoot`. **Hardcode this ref.** Do not derive it from `NEXT_PUBLIC_SUPABASE_URL` or any env var in the scheduler repo — those resolve to **staging** (ref `mjdrysyrqgfhsyakssce`), not production.
- **Staging** — use the normal client path (`NEXT_PUBLIC_SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` from `.env.local`, or `E2E_SUPABASE_URL` / `E2E_SUPABASE_SERVICE_KEY` for e2e). No Keychain, no Management API — staging needs none of this.

Query or apply SQL against production via the Management API's `database/query` endpoint:

```bash
PAT=$(security find-generic-password -s "supabase-pat" -w)
curl -s "https://api.supabase.com/v1/projects/ywwnprpncqrqfiskmoot/database/query" \
  -H "Authorization: Bearer $PAT" \
  -H "Content-Type: application/json" \
  -d '{"query":"select count(*) from public.visits;"}'
```

Only applying a change (not reading) to production is governed by the scheduler repo's own migration policy and JP-approval rules (destructive DDL, risky list, etc. — see `~/dev/scheduler/CLAUDE.md` "Database Standards" / "Migration policy"). This skill is about *how to reach* production, not about when you're allowed to.

## Recording an apply in the migration ledger

Every migration applied to production must be recorded in `public.scheduler_migration_ledger` (append-only). Preferred path — run the scheduler repo's own script:

```bash
cd ~/dev/scheduler
npx tsx scripts/migration-ledger.ts record <filename> --by <name> --env production
```

That script reads `NEXT_PUBLIC_SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` from the environment and derives/validates the environment from the URL — it will refuse if those point at staging while you pass `--env production`. If you can't get it to run with a working production connection, fall back to a direct Management API INSERT with the same row shape (`filename, checksum, environment, status, evidence, applied_at, applied_by, note`; checksum is sha256 of the raw migration file bytes, e.g. `shasum -a 256 <file>`):

```bash
PAT=$(security find-generic-password -s "supabase-pat" -w)
CHECKSUM=$(shasum -a 256 supabase/migrations/<file> | awk '{print $1}')
curl -s "https://api.supabase.com/v1/projects/ywwnprpncqrqfiskmoot/database/query" \
  -H "Authorization: Bearer $PAT" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"INSERT INTO public.scheduler_migration_ledger (filename, checksum, environment, status, evidence, applied_at, applied_by, note) VALUES ('<file>', '$CHECKSUM', 'production', 'applied', 'recorded', now(), '<name>', NULL) ON CONFLICT DO NOTHING;\"}"
```

Use the direct-INSERT fallback only when the script genuinely can't run — it bypasses the script's own guards (environment-match check, checksum computation), so double-check `filename`/`checksum`/`environment` by hand before sending it.

## Helper script

`query-prod.sh <sql>` in this folder wraps the Keychain lookup + curl for the common read-only case. It never echoes the token.
