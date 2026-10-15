# CI runners (self-hosted, label `benjis-ci`)

`setup.sh` turns a fresh VM into N ephemeral GitHub Actions runner slots (rootless Docker, user `gha`,
cgroup-limited). Design: #205. It is idempotent: a second run prints `no change`.

## Usage
```
sudo infra/ci-runners/setup.sh [--slots N] [--runner-version X.Y.Z] [--check] [--mint-from-stdin] [--probe]
```
- `--slots N` (1..16, default 2; 3 only after a measured gate). Shrinking disables and stops the higher slots.
  Per-user `MemoryMax` is 2.5G x slots.
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
2. Supply `mint.env` (and `alert.env`, `sentry.env`) as above.
3. Run `infra/ci-runners/setup.sh --probe`; every line must be PASS.
4. Confirm the `benjis-ci` runners show Idle in GitHub (JIT runners register themselves on first start).
5. Flip the org variable `CI_RUNNER_JSON` to the new runners; flip it back to roll back.

## Rollback
`sudo systemctl disable --now 'gha-slot@*' gha-hygiene.timer`, set `CI_RUNNER_JSON` back to the hosted runners, then
remove `/etc/systemd/system/gha-slot@.service`, `gha-hygiene.*`, the `user-<uid>.slice.d` / `user@<uid>.service.d`
drop-ins and `systemctl daemon-reload`. User `gha` and `/srv/gha` are left in place.
