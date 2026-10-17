# CI runners (self-hosted, label `benjis-ci`)

`setup.sh` turns a fresh VM into N ephemeral GitHub Actions runner slots (rootless Docker, user `gha`,
cgroup-limited). Design: #205. It is idempotent: a second run prints `no change`.

## Where CI runs (read this first)
- Workflows pick their runner with `runs-on: ${{ fromJSON(vars.CI_RUNNER_JSON || '"ubuntu-latest"') }}`. The org variable
  `CI_RUNNER_JSON` is the switch: `"benjis-ci"` sends the job to any of our self-hosted slots, unset sends it to GitHub-hosted.
  Nothing in the agent pipeline chooses a runner; GitHub hands each job to whichever `benjis-ci` slot is free, on any host.
- Hosts (each runs `setup.sh`; slots from every host share the one `benjis-ci` label):
  - Clog VM (`claude@178.156.187.130`, Hetzner, 8 vCPU / 16 GB, also runs the agent pipeline): 3 slots.
  - CI host `CI-ubuntu-8gb-ash-2` (`root@178.156.204.167`, Hetzner CPX31-class, 4 vCPU / 8 GB, CI only): 2 slots.
- Today the variable is scoped to the scheduler repo only; the quoting tool stays on GitHub-hosted until its container-mode
  workflow is on its `main` branch (#205).
- `setup.sh` is installed from one pinned commit into `/opt/gha-ci` (SHA in `/opt/gha-ci/SHA`); update by re-extracting
  `infra/ci-runners` from the new commit and re-running `setup.sh --slots N`.

## Metrics (where are the bottlenecks?)
Every host logs under `/var/log/gha/` (capped: 14 days of samples, last 5000 runner lives; trimmed by the daily hygiene run):
- `host.csv`: one row per minute from `gha-metrics.timer`: `ts,memavail_mb,swap_used_mb,load1,steal_pct,disk_pct,gha_mem_mb,gha_oom_kills,slots_up,jobs_running`.
- `jobs.jsonl`: one line per ephemeral runner life from the launcher: `ts, slot, runner, life_seconds, rc` (`rc` 137 = killed, usually out of memory).

`infra/ci-runners/ci-report.sh [--days N] [--runs N]` (run on the Mac) joins the GitHub job data (queue wait and run time per
job, self-hosted vs hosted) with the host samples and prints the top bottlenecks plus a plain suggestion (add a slot, memory-bound,
noisy CPU, disk). `HOSTS="claude@178.156.187.130 root@178.156.204.167" infra/ci-runners/ci-report.sh --days 7`.

## Prerequisites
Docker (with `dockerd-rootless-setuptool.sh`), `uidmap`, `curl`, `jq`, systemd. On Ubuntu: `apt-get install docker.io rootlesskit slirp4netns uidmap curl jq`, then symlink `docker`, `dockerd`, `containerd`, `runc`, `rootlesskit`, `dockerd-rootless.sh` and `dockerd-rootless-setuptool.sh` into `/usr/local/bin`.

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
