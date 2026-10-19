# Keeping the Mac and the Clog VM in sync

One page. Why: on 2026-10 the VM ran stale pipeline code for days because the only sync was the SessionStart hook, which cron and launchd ticks never run (claude-agents#424). Hosts also drifted in tool versions, git hooks, env files and memory.

Principle: **sync what can be derived from git automatically, check-and-alert everything else, and write down what is deliberately different.** The source of truth is `infra/host-manifest.json` (names, paths, version floors; never a secret value).

## 1. Synced automatically

| What | How |
|---|---|
| Pipeline code (`agents/ hooks/ skills/ CLAUDE.md settings.json`) | Every supervisor tick runs `skills/orchestrate/code-sync.sh` first: fetch, fast-forward `main`, re-exec the tick on the new code. Interactive sessions still pull via `hooks/sync-agents.sh`. |
| Refuse to run stale | If the checkout is behind `origin/main` and cannot fast-forward (other branch, dirty tracked tree, diverged), the tick logs `[code-sync] STALE` and launches nothing. Offline (fetch fails) is not stale: GitHub is down too. Kill switch: `CODE_SYNC_ENABLED=0` in `config.local.sh`. |
| Git hooks path | `bin/host-drift.py --fix` points `core.hooksPath` at the repo's `.githooks` (or unsets a dead path) in manifest repos. |
| Stale `claude` on non-interactive PATH (VM) | `--fix` puts `~/.local/bin` first in `~/.bashrc` (before the interactive guard). |
| Claude Code / node versions seen by agents | `config.sh` prepends the pinned node major (22, matches CI) from Homebrew `node@22` when present; claude must be the newest on PATH. |
| Missing optional-to-auto clones | `auto_clone` entries in the manifest are cloned by `--fix`. |
| Memory (`~/.claude/projects/*/memory`) | `bin/memory-sync.py` hourly through ONE private git remote (`MEMORY_REMOTE` in `~/.claude/pipeline/memory-sync.conf`). 3-way merge per file, conflicts keep both copies, `MEMORY.md` is line-unioned, nothing is ever deleted, files that look like credentials are refused. **Inactive until JP chooses the remote.** |

## 2. Checked daily, alerted only on drift

`bin/host-drift.py --fix --alert` runs daily on both hosts (Mac launchd `com.jp.host-drift`, VM cron). It prints nothing when clean. When the set of drift items changes it opens or updates one issue per host, "Host drift: mac" / "Host drift: vm" (label `host-drift`, jpmoya/claude-agents), and closes it when clean. Its latest snapshot is `~/.claude/pipeline/host-snapshot.json`.

Checked: `~/.claude` symlinks; claude-agents behind origin/main; node major, claude/gh/wrangler floors and PATH order; per-host config values and the 1000/day push budget; supervisor schedule loaded; required clones; required env files (presence only, values never read); `gh` login and scopes; wrangler login; headless claude login file; memory sync freshness.

Reported in the snapshot but not alerted: dirty trees, detached HEADs, stale `.env*.bak*` copies, older claude binaries elsewhere on PATH, pending decisions.

## 3. Deliberately per-host

- `MAX_CONCURRENT` (Mac 7, VM 4) and `MAX_PUSHES_PER_DAY` (Mac 550 + VM 450 = the 1000/day KV cap): recorded in the manifest, so a change is a manifest edit, not silent drift.
- Supervisor phase (Mac odd minutes via launchd, VM even minutes via cron) and `DISPATCH_REPOS` (the Mac also has Business-Intelligence, which is never on the VM).
- Claude login: Mac uses the long-lived `~/.claude/pipeline/oauth-token`; VM uses its own `.credentials.json` login. Tokens are never copied by these tools.
- Folder names: Mac `~/dev/<repo>`, VM `~/<repo>` (VM quoting tool is still `~/benjis-quoting-tool`); the manifest maps both.
- Secrets and env files are host-local. `bin/vm-sync.sh creds` is the one existing Mac-to-VM copy path; drift only reports a missing file.
- Mac-only: iOS release env files, Business-Intelligence, Lechuza, personal apps. VM-optional: the personal repos and the new website.
- `/tmp/pipeline` run state stays local (claude-agents#332 tracks surviving reboots).

## Install

```
git pull && bin/host-sync-install.sh      # on each host
```
Then `python3 bin/host-drift.py` (dry run) should print nothing.

## Open items that are JP's call

1. Memory store: a private git remote, then set `MEMORY_REMOTE=` on both hosts.
2. `benjis-design-system` is a plain folder, not a git repo anywhere; the VM cannot get it until it is hosted.
