# Where things run

Three different questions, never blur them: where a job **executes** (a runner), what **triggers** it (GitHub Actions), and what runs on the **VM / Mac** (the agent pipeline).

**Authoritative and live: `skills/orchestrate/where-things-run.sh`.** It reads the runner variables and runner lists from GitHub for the ops tool and the sales tool and flags anything wrong. This page is only a map; if the two disagree, the script wins. Never answer "where does X run" from workflow YAML or its comments.

## The rule about `ubuntu-latest`

A workflow line like `runs-on: fromJSON(vars.CI_RUNNER_JSON || '"ubuntu-latest"')` uses `ubuntu-latest` (GitHub-hosted) **only when the variable is unset or empty**. With the variables set (org `CI_RUNNER_JSON`, repo `HOSTED_JOBS_RUNNER_JSON` on the ops tool, repo `PROD_DEPLOY_RUNNER_JSON` on both) that fallback is never taken. Some jobs fall back to `"benjis-ci"` instead. `HOSTED_JOBS_RUNNER_JSON` is a deliberate switch: deleting it sends the ops tool's short PR checks and staging-merge jobs back to GitHub-hosted. A set variable whose runners are all gone does not fall back either: the job queues until a runner appears. Comments in workflows that say "GitHub-hosted" can be stale (see the script's output for the truth).

## Components

| Component | Trigger | Executes on | Proof |
|---|---|---|---|
| PR checks (ops tool, sales tool) | GitHub Actions `pull_request` | self-hosted `benjis-ci` slots (the ops tool's short checks read `HOSTED_JOBS_RUNNER_JSON`, the rest `CI_RUNNER_JSON`) | `skills/orchestrate/where-things-run.sh` |
| Staging deploy | `push` to `staging` (ops tool also a 15-minute `schedule`) | `benjis-ci`; full e2e on `benjis-ci-bulk` | same; `gh variable list -R <owner>/<repo>` (repo variables only) |
| Prod deploy, migrations | `push` to `main` | `benjis-ci-prod-deploy` (one slot, takes only jobs labelled for prod deploy) | `gh api orgs/<owner>/actions/runners` |
| Router / auto-release | `workflow_run` after CI, hourly `schedule` | prod-deploy slot (ops tool and sales tool `main`) | same |
| Release announce, post-release cleanup | `workflow_run` after the prod deploy | prod-deploy slot | same |
| Sentry intake | `schedule` (ops tool every 15 min) | `benjis-ci` | same |
| Mobile release (ops tool) | `push` | Android on `benjis-ci` or the Mac, iOS on the Mac runner `jp-mac-mobile` (`MOBILE_MAC_RUNNER_JSON`) | same |
| This repo's `ci-metrics.yml` | `schedule` | GitHub-hosted `ubuntu-latest` (literal, so it works when the pool is down) | `grep runs-on .github/workflows/ci-metrics.yml` |
| Supervisor | Mac: launchd, odd minutes; VM: cron, even minutes | the Mac and the Clog VM | `launchctl list \| grep pipeline-supervisor`; `ssh clog-exec 'crontab -l \| grep supervisor'` |
| Orchestrator and stage agents | launched by the supervisor or `launcher.sh` as `claude --agent <name> -p` | the Mac or the VM | `skills/orchestrate/launcher.sh status` |
| Status page | hosts POST heartbeats | Cloudflare Worker `status-page`, fronted by Vercel (`pipeline-status-jp.vercel.app`, Google sign-in) | `status-page/wrangler.jsonc` |

Runner hosts: the `gha-CI-*` slots are the Hetzner CI host, the `gha-Claude-*` slots are the Clog VM (which also runs the supervisor and agents), `jp-mac-mobile` is JP's Mac (see `infra/ci-runners/README.md`). Slot labels and counts change: read them from the script, not from here.

`schedule` is the one trigger GitHub does not run reliably, so anything that must happen on time should not depend on it (moving the scheduled triggers onto the VM supervisor is claude-agents#769, move scheduled release/CI triggers).
