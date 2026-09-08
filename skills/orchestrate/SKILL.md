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

`supervisor.sh` runs every 2 minutes from cron on both machines — VM on even minutes (`*/2`), Mac on odd (`1-59/2`) — logging to `~/logs/pipeline/supervisor.log`. Each tick, in order, at most one launch:

1. **Restart** exited orchestrators whose latest marker is not terminal, with backoff (2/5/15/30 min; short-lived exits count as transient with their own longer table). After 3 restarts without marker progress or 6 total it posts a `**[supervisor] NOTE**` on the issue and parks the run (`held`).
2. **Drain** the local queue when a slot is free.
3. **Labels:** drop `agent-in-progress` on issues this machine finished (`done`: DEPLOYED / APPLIED / closed), parked (`held`: MOCKUPS PENDING APPROVAL, AWAITING GO, BLOCKED after the 20-min grace, or escalation), or JP stopped.
4. **Shared dispatch:** if this machine's `DISPATCH_REPOS` is set, list open `agent-go` issues without `agent-in-progress` across those repos and launch the first one it has capacity for — after posting a claim NOTE (`**[supervisor] NOTE** claim: <host> <ts>`), waiting 15 s, and confirming its claim is the earliest in the last 10 minutes. Lost claims are logged and skipped. On a Mac, dispatch runs only on AC power (restarts and drains always run).

Config: shared defaults in `skills/orchestrate/config.sh` (labels, caps, backoff). Per machine, untracked, `~/.claude/pipeline/config.local.sh` sets `DISPATCH_REPOS=("owner/repo:/local/checkout" …)` — VM: casa-verde-site, rfp-finder, scheduler; Mac: those plus quoting tool and Business-Intelligence. Empty list = that machine only runs what is launched on it by hand.

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

## Rules

- Never `Agent(subagent_type: orchestrator)` from an interactive session. The `block-orchestrator-agent.sh` hook rejects it; the headless process the script starts is exempt via `PIPELINE_HEADLESS=1`.
- Never run the launch command in the foreground or with the Bash tool's `run_in_background` — the script already detaches with `nohup`.
- Do the other work JP asks for in this session as usual; the orchestrator is unaffected by what happens here.
