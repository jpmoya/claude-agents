# claude-agents

JP's shared Claude Code config, synced across machines (Mac + Clog VM). Despite the name it now holds everything global, not just agents.

| Path | Symlinked to | Contents |
|---|---|---|
| `agents/` | `~/.claude/agents` | pipeline agent definitions |
| `hooks/` | `~/.claude/hooks` | hook scripts (all cross-platform; `cap-heavy-commands.py` is VM-only and wired from the VM's local settings if wanted) |
| `skills/` | `~/.claude/skills` | user skills |
| `CLAUDE.md` | `~/.claude/CLAUDE.md` | global instructions |
| `settings.json` | `~/.claude/settings.json` | shared settings: permissions, cross-platform hooks, skillOverrides, marketplaces, effort/advisor |

**Machine-specific settings stay in `~/.claude/settings.local.json`** (not tracked): model, theme, tui, plugin toggles, notification-sound hooks, `outputStyle`, `disabledMcpjsonServers`. Claude Code merges it over `settings.json`. Secrets never go here — `~/.claude/mcp-servers/`, `.mcp.json`, memory and `~/.claude.json` stay local.

- A `SessionStart` hook (`hooks/sync-agents.sh`) runs `git pull --ff-only` here, so every session starts with the latest config, and prints a warning if any symlink has been replaced by a real file.
- To change anything: edit here (or through the symlink), commit, push. Other machines pick it up on their next session.
- **No repo-local agents.** A repo's `.claude/agents/` holds at most `deployer.md`, which the orchestrator looks for locally. Nothing else: project-level agents override user-level ones, so a local `code-reviewer` silently replaces the pipeline one, and a repo-prefixed fork drifts from the global definition (casa-verde-site's did, 2026-09-03). Repo-specific rules go in that repo's `CLAUDE.md`, which every global agent reads.

## Install on a new machine

```bash
git clone https://github.com/jpmoya/claude-agents.git ~/dev/claude-agents   # VM: ~/claude-agents
cd ~/.claude && mkdir -p backups/pre-dotfiles && mv agents hooks skills CLAUDE.md settings.json backups/pre-dotfiles/ 2>/dev/null
R=~/dev/claude-agents; for i in agents hooks skills CLAUDE.md settings.json; do ln -s $R/$i ~/.claude/$i; done
# then put machine-specific keys in ~/.claude/settings.local.json
```

Pipeline: product-manager → ux-flow-designer (UI tickets: user flow — screens, states, copy) → ui-ux-designer (UI tickets: mockups of that flow, JP approval gate) ∥ solutions-architect (architecturally significant tickets) → **test-writer** (failing tests + stubs from the ACs, committed to the feature branch) → **test-reviewer** (pre-implementation: AC coverage, falsifiability) → fullstack-developer (implements against the locked tests; may add tests in new files, never edits locked ones — enforced by `hooks/protect-locked-tests.sh` + the orchestrator's byte-identical diff) → code-reviewer [+ test-reviewer narrow, only on added tests] → deployer (global; a repo may override with its own `deployer.md`). Scheduler caveat: the deployer merges scheduler PRs to `staging` only — staging migrations, Actions deploy, E2E — and JP promotes `staging` → `main` to production himself; the deployer never touches scheduler `main`. `orchestrator` dispatches stages by reading `**[agent] MARKER**` comments on the GitHub issue. **Comment protocol:** every agent starts every comment with `**[agent] MARKER**` on line 1 — a routing marker for handoffs, `NOTE` for anything else (the orchestrator skips NOTEs). The orchestrator reads first lines only (jq), never the full thread. `hooks/require-handoff-marker.sh` (Stop/SubagentStop) refuses to let a stage finish until its marker is on the issue, using the `PIPELINE_ISSUE/AGENT/REPO` coordinates the orchestrator exports per launch; a no-marker run gets one handoff-only recovery dispatch before it's reported. `orchestrator` and `deployer` run on Sonnet (mechanical stages); the rest inherit the session model. The orchestrator itself is launched headless via `skills/orchestrate` (never as a subagent — `hooks/block-orchestrator-agent.sh` enforces it).

Why tests are authored separately: tests written by the implementer inherit its misreading of the spec (AgentCoder, arXiv 2312.13010). Independent authoring plus a mechanical lock means the test review runs once, early, instead of after every fix cycle.
