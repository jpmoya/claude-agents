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

## Auto-restart (supervisor)

A cron job runs `supervisor.sh` every 2 minutes (install per machine: `crontab -e` → `*/2 * * * * ~/.claude/skills/orchestrate/supervisor.sh`; the Mac was missing it until 2026-09-08, so nothing auto-restarted or drained the queue there). It detects exited orchestrators with non-terminal markers and auto-restarts them with backoff (2min, 5min, 15min, 30min). After 3 restarts without marker progress or 6 total, it escalates by posting a `**[supervisor] NOTE**` on the issue and stops retrying.

- `stop` writes a tombstone — the supervisor will not auto-restart a manually stopped orchestrator.
- A manual `orchestrate.sh <repo> <issue>` clears tombstones and restart state.
- `status` shows the state: `running`, `exited (will auto-restart)`, `stopped (manual)`, `held (needs JP)`, or `done`.

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
