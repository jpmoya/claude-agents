---
name: orchestrate
description: Launch the pipeline orchestrator for a GitHub issue as a detached headless process, or check/stop a running one. Use whenever JP asks to run, drive, resume, or check on the pipeline for an issue ("orchestrate #547", "run the pipeline on 547", "where is 547 at"). Never dispatch the orchestrator with the Agent tool — a subagent dies when this session compacts or exits.
---

# Orchestrate (headless)

The orchestrator must outlive this session. Subagents don't: they run inside the parent process and die on compaction, restart, or exit. So the orchestrator is launched as its own `claude -p` process via the script in this skill, and this session only reads its status.

## Launch

```bash
~/.claude/skills/orchestrate/orchestrate.sh <repo-path> <issue> [extra instructions]
```

- `<repo-path>`: the repo's main checkout (e.g. `~/dev/scheduler`, or `~/scheduler` on Clog). The script resolves `owner/repo` with `gh`.
- Extra instructions are appended to the orchestrator's prompt verbatim — use them for context it can't read from the issue (e.g. "config blocker resolved, retry from test-writer").
- One orchestrator per issue; the script refuses to launch a second while the first is alive.
- Max 3 concurrent orchestrators (VM has 3.7GB RAM, 1200MB memory floor). If all slots are full or memory is low, the launch is queued automatically and the supervisor launches it when capacity is available. `status` shows both running and queued.
- It prints the PID and log path (or "queued" if at capacity). Report to JP and stop. Do not poll, do not wait, do not tail in a loop.

## Supervisor (one cron tick does everything)

`supervisor.sh` runs every 2 minutes on both machines — VM from cron on even minutes (`*/2`); Mac from a launchd user agent on odd minutes (`~/Library/LaunchAgents/com.jp.pipeline-supervisor.plist`, `StartCalendarInterval`), because macOS cron jobs have no keychain access and `claude -p` reports `Not logged in` (2026-09-13). Both log to `~/logs/pipeline/supervisor.log`. Each tick, in order, at most one launch:

1. **Restart** exited orchestrators whose latest marker is not terminal, with backoff (2/5/15/30 min; short-lived exits count as transient with their own longer table using per-launch timing via `.launched-at`). After 3 restarts without marker progress or 6 total it posts a `**[supervisor] NOTE**` on the issue and parks the run (`held`).
2. **Drain** the local queue when a slot is free.
3. **Labels:** drop `agent-in-progress` on issues this machine finished (`done`: DEPLOYED / APPLIED / closed), parked (`held`: MOCKUPS PENDING APPROVAL, AWAITING GO, BLOCKED after the 20-min grace, or escalation), JP stopped, or dead with no pending relaunch in the queue.
4. **Label reconciliation:** scan `DISPATCH_REPOS` for open issues carrying `agent-in-progress` with no local pid file and no queue entry. If the issue's last comment is older than 30 minutes, clear the label — it's orphaned (the machine that owned it died or lost `/tmp`). This prevents the "running elsewhere?" deadlock where no machine can claim a dead run.
5. **Shared dispatch:** if this machine's `DISPATCH_REPOS` is set, list open `agent-go` issues without `agent-in-progress` across those repos and launch the first one it has capacity for — after posting a claim NOTE (`**[supervisor] NOTE** claim: <host> <ts>`), waiting 15 s, and confirming its claim is the earliest in the last 10 minutes. Lost claims are logged and skipped. On a Mac, dispatch runs only on AC power (restarts and drains always run).

Config: shared defaults in `skills/orchestrate/config.sh` (labels, caps, backoff). Per machine, untracked, `~/.claude/pipeline/config.local.sh` holds the repo lists.

- **Dispatch eligibility** is per machine: `DISPATCH_REPOS=("owner/repo:/local/checkout" …)` lists the repos whose `agent-go` issues this machine's supervisor may launch — VM: casa-verde-site, rfp-finder, scheduler; Mac: those plus quoting tool and Business-Intelligence. Empty list = that machine only runs what is launched on it by hand.
- **Scan coverage** is separate and lives on the one `SCAN_BACKLOG=1` machine (the VM): the hourly `scan-backlog.sh` labels unlabelled open issues `agent-proposed` across that machine's `DISPATCH_REPOS` plus `SCAN_ONLY_REPOS=("owner/repo" …)`, each repo at most once. `SCAN_ONLY_REPOS` (default empty = scan exactly `DISPATCH_REPOS`) is read by the scan alone — the supervisor and the launcher never see it, so listing a repo there never makes a machine dispatch it. The quoting tool is scanned on the VM through `SCAN_ONLY_REPOS` and dispatched only from the Mac. Business-Intelligence is in neither the scan nor any automatic queue — it is on no list of the scanning machine, so nothing ever proposes it, and the Mac launches a Business-Intelligence issue only after JP himself adds `agent-go`.

Label rule: `agent-go` = "approved, not launched anywhere yet"; launching anywhere swaps it for `agent-in-progress`; the supervisor removes `agent-in-progress` when the run is done or parked. To run a parked issue again, relaunch by hand or re-add `agent-go`.

- **Per machine.** `/tmp/pipeline` (pids, queue, tombstones) is local; the only shared state is the issue's markers and labels. The launcher refuses an issue that carries `agent-in-progress` and isn't owned here ("running elsewhere?"); `orchestrate.sh --force <repo> <issue>` overrides when the other machine is known dead.
- `stop` writes a tombstone — the supervisor will not auto-restart a manually stopped orchestrator.
- A manual `orchestrate.sh <repo> <issue>` clears tombstones and restart state and supersedes a queued entry.
- `status` shows the state: `running`, `exited (will auto-restart)`, `stopped (manual)`, `held (needs JP)`, or `done`; `!! ALERT` lines say why something is held.

## Check on a run

```bash
~/.claude/skills/orchestrate/orchestrate.sh status          # every recorded orchestrator: running/exited + latest issue marker
~/.claude/skills/orchestrate/orchestrate.sh status 547
~/.claude/skills/orchestrate/orchestrate.sh tail 547 40     # last 40 lines of the orchestrator's log
```

The issue's latest marker is the truth; the log is for diagnosing a stall. Stage logs the orchestrator writes are in `/tmp/pipeline/run-<issue>-<agent>.log`, and its run log is `~/.claude/pipeline/runs.jsonl`.

## Resume after a crash

The supervisor handles this automatically now. If you need to force-restart immediately (instead of waiting for the next supervisor tick), just launch again — it clears any tombstones and restart state.

## Stop

```bash
~/.claude/skills/orchestrate/orchestrate.sh stop 547
```

Stops the orchestrator and writes a tombstone preventing auto-restart. A stage it already launched (e.g. fullstack-developer) keeps running and will still post its marker; relaunch afterwards to pick it up.

## Status board (issue #10)

Each host pushes a heartbeat (running/queued/held/restarting runs, capacity, last activity) to a shared status page whenever `skills/orchestrate/report-status.sh` decides something changed or the keep-alive interval elapsed. It is a silent no-op — no network call at all — until `~/.claude/pipeline/config.local.sh` sets both `STATUS_PUSH_URL` (the deployed status-page Worker's `/beat` endpoint) and `STATUS_PUSH_TOKEN` (this host's bearer secret); both come from the companion infra issue once it deploys. Never invoked directly by a call site — `orchestrate.sh`, `supervisor.sh` and `hooks/report-status-hook.sh` all go through `report_status_async` (`skills/orchestrate/run-state.sh`), which backgrounds it, redirects its output to `~/logs/pipeline/report-status.log`, and can't propagate a failure back to the caller.

The status page is public (no auth, `noindex` only). Since issue #29 each run's **issue title and GitHub issue URL are published** on it (JP's decision, 2026-09-19), so `owner/repo` appears in the payload inside `runs[].url` and nowhere else. `orchestrate.sh` fetches the title once at launch (before the capacity check, so queued runs get one too) into `$PIPE/orch-<issue>.title`; `supervisor.sh` `do_launch` fetches it only if that file is missing. The reporter only reads the file — a beat never makes a network call for a title, and a missing, empty or unreadable file just means the run is sent without `title`/`url` and shows an empty Ticket cell.

`STATUS_REPO_ALIASES=("owner/repo:alias" …)` in `config.local.sh` still populates `runs[].repo` in the payload and `/status.json` — a repo absent from the map publishes as `"other"` — but the alias is no longer shown in the HTML table. See `config.local.example.sh` for the placeholder form.

## Rules

- Never `Agent(subagent_type: orchestrator)`, from any session. The `block-orchestrator-agent.sh` hook rejects it with no exemption; the script starts the orchestrator as the main agent of its own process (`claude --agent orchestrator -p`), so nothing needs that call.
- Extra instructions carry instructions, never claims of verified state ("already fixed", "returns 200") — the orchestrator rightly distrusts them and stalls.
- Never run the launch command in the foreground or with the Bash tool's `run_in_background` — the script already detaches with `nohup`.
- Do the other work JP asks for in this session as usual; the orchestrator is unaffected by what happens here.
