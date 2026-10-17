# CI runners (self-hosted, label `benjis-ci`)

`setup.sh` turns a fresh VM into N ephemeral GitHub Actions runner slots (rootless Docker, user `gha`,
cgroup-limited). Design: #205. It is idempotent: a second run prints `no change`.

## Prerequisites
Docker (with `dockerd-rootless-setuptool.sh`), `uidmap`, `curl`, systemd.

## Usage
```
sudo infra/ci-runners/setup.sh [--slots N] [--runner-version X.Y.Z] [--check] [--mint-from-stdin] [--probe]
```
- `--slots N` (1..16, default 2; 3 only after a measured gate). Shrinking disables and stops the higher slots.
  Per-user `MemoryMax` is 4G x slots (CI job containers are capped at 4G).
- `--runner-version` pins actions/runner (default 2.338.0); image is built locally as `gha-runner:<version>`.
- `--check` changes nothing, prints `WOULD CHANGE:` / `OK:` per step, exits 0 (nothing to do) or 3 (changes pending). No root needed.
- `--mint-from-stdin` stores the registration token root-only in `/etc/gha/mint.env` (0600); never echoed or put in argv.
- `--probe` (same as `probe.sh`) asserts `gha` cannot read `~claude/.claude`, `.config`, `.ssh`, cannot list `/home/claude`,
  and has no TOKEN/SECRET/KEY env names. Exit non-zero on any FAIL.
- Exit codes: 0 ok, 1 step failure, 2 bad arguments, 3 `--check` found changes.

## Manual inputs (never in the repo)
- `/etc/gha/mint.env` (root:root 0600): `GHA_MINT_TOKEN=<token able to create JIT runner configs>` and
  `GHA_RUNNER_SCOPE=orgs/<org>` (or `repos/<owner>/<repo>`). Slots stay idle until this file exists; then
  `systemctl start 'gha-slot@*'`.
- `/etc/gha/alert.env`: `SLACK_WEBHOOK_URL=<the existing webhook>`. Without it disk/failure alerts are silent.
- `/etc/gha/sentry.env` (optional): `SENTRY_DSN=...`. Failures (mint, prune, setup step) send one event tagged
  `release` (deployed commit SHA), `environment=ci-runner`, `route`. Without it Sentry is skipped silently.

## Move to another VM
1. Run `sudo infra/ci-runners/setup.sh --slots 2` on the new VM.
2. Supply `mint.env` (and `alert.env`, `sentry.env`) as above, then start the slots: re-run `setup.sh --mint-from-stdin`
   or `systemctl start gha-slot@1 gha-slot@2`.
3. Run `infra/ci-runners/setup.sh --probe`; every line must be PASS.
4. Confirm the `benjis-ci` runners show Idle in GitHub (JIT runners register themselves on first start).
5. Flip the org variable `CI_RUNNER_JSON` to the new runners; flip it back to roll back.

## Rollback
`sudo systemctl disable --now 'gha-slot@*' gha-hygiene.timer`, set `CI_RUNNER_JSON` back to the hosted runners, then
remove `/etc/systemd/system/gha-slot@.service`, `gha-hygiene.*`, the `user-<uid>.slice.d` / `user@<uid>.service.d`
drop-ins and `systemctl daemon-reload`. User `gha` and `/srv/gha` are left in place.

## CI job metrics (issue #356)
`scripts/ci-metrics.sh` (`collect | rollup | weekly`) reads the Actions API for the repos in `scripts/ci-metrics.repos` (plus `SLOTS=`, the total runner slots used for busy %). The daily workflow `.github/workflows/ci-metrics.yml` runs on `ubuntu-latest` (so it works when the pool is down) and commits `metrics/ci-jobs.jsonl` (append-only, deduped by job id, 90-day retention) and `metrics/ci-daily.json` (median/p90 run and queue time per job, longest queue wait, jobs per runner, slot busy %) to the orphan branch `ci-metrics`. On Mondays it posts one Slack summary with a suggested change (`add slot`, `split job` or `no change`). Failures go to Sentry (route `ci-metrics/<step>`, release = commit SHA) and the existing Slack webhook. Secrets used: `RELEASE_BOT_TOKEN` (cross-repo read), `SLACK_WEBHOOK_URL`, `SENTRY_DSN`.
