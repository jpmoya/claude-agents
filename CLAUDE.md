# Cross-project conventions

## Communication style

Be concise. JP needs to make quick decisions unless something is mission critical, so keep answers short and in layman's terms. Don't ask JP technical questions — decide from evidence and defaults, and flag only what truly needs his call.

## Software development

JP does not do hands-on engineering in the main session. Every code change in any of JP's repos — features, bug fixes, regressions, refactors — goes through the agent pipeline: file/refine the GitHub issue, then launch the `orchestrator` with the `orchestrate` skill (`~/.claude/skills/orchestrate/orchestrate.sh <repo> <issue>`), which runs it as a detached headless process. Never dispatch the orchestrator with the Agent tool — a subagent dies when the session compacts or exits (orch-547, 2026-09-05); `block-orchestrator-agent.sh` blocks it in every session, no exceptions. The launcher runs the orchestrator directly as the main agent of its headless process (`claude --agent orchestrator -p`), so no Agent call is involved. The orchestrator dispatches pipeline stages (test-writer, fullstack-developer, etc.) as separate `claude --agent <stage> -p` processes from Bash. Check progress with `orchestrate.sh status`; relaunch to resume, state lives in the issue's markers. Do not edit application code, create branches, or open PRs directly from the main session.

**Who writes tickets.** The main session never hand-writes a pipeline ticket through an ad-hoc `general-purpose` subagent. Either dispatch `product-manager` to write it, or file a short brief and launch the orchestrator so the PM stage refines it before anything else happens. A ticket must not reach JP with a blocking "Open questions for JP" section: the PM decides from evidence (consulting the solutions-architect on technical questions) and lists whatever is left as non-blocking questions with a stated default. Only JP-only items may block: spending money, a prod `go`, where a private artefact is stored / who gets access, external communications. A dependency follow-up of a ticket JP already approved is filed by the PM with a `Parent: owner/repo#N` line and inherits `agent-go` — the rule and its exclusions (new scope, Business-Intelligence) live in `agents/product-manager.md`.

**Pipeline incidents and pipeline changes.** Before proposing or filing any change to the pipeline itself (`agents/`, `hooks/`, `skills/orchestrate`) — including after a run holds, exits or restarts unexpectedly — run `pipeline-diagnostician` on the incident, then `pipeline-adjudicator` in a fresh context with the diagnostician's final report (verbatim) and the proposal's issue number if one exists, and give JP the verdict card. The adjudicator files and queues (`agent-go`) its own fix ticket on `jpmoya/claude-agents` when the verdict is `CHANGE? YES` with no new mechanism; the card is informational, and the main session that ran the review carries out any `DO NOW` items (host/config fixes, falsifier launches) without asking JP. Only a fix that adds a mechanism (a design call) or a JP-only item (spending money, a prod `go`, where a private artefact is stored / who gets access, external communications) goes to JP for approval. Run them from the Mac (the VM cannot reach the Mac). These two are ordinary agents, not pipeline stages: launching them with the Agent tool or `claude --agent <name> -p` is fine — the orchestrator ban does not apply.

**Status answers.** Whenever JP asks for status, an update or "where is X" on pipeline work, answer with this card, one per run, under 20 lines, plain language, no jargon (no marker names, PIDs or stage names). Build it from `orchestrate.sh status <issue>` plus the issue's latest markers and PRs, so it works however the run was started (manual, `/orchestrate`, supervisor dispatch). Never hand-roll a different layout.

```
<Ticket title> (<repo> #<issue>) — PR #<n> · release <version | none yet>
STATUS:    <RUNNING | WAITING ON YOU | BLOCKED | HELD | STALLED, retrying | DEPLOYED | DONE>
WHAT'S UP: <one sentence, layman's terms>
NEEDED FROM YOU: <bulleted list, e.g. "staging review is ready", "missing: A, B, C"; "Nothing" if none>
TECHNICAL PROBLEM: <No | Yes — one line: run killed / stopped unexpectedly / restarted, and why>
SELF-HEAL TICKETS: <owner/repo #n — open/queued/fixed, one line each; if a technical problem happened and no ticket exists, say so and that the diagnostician → adjudicator run is owed>
```

A technical problem (run killed, exited, restarted, held unexpectedly) means the diagnostician → adjudicator flow above is owed: launch it, don't just report it. Never trigger it silently into filing — the verdict card still goes to JP first.

Never add any file to a repo's `.claude/agents/` other than `deployer.md` — no repo-prefixed forks either. Project-level agents override global ones and break the orchestrator, and forks drift. Repo-specific rules belong in that repo's `CLAUDE.md`. See `~/dev/claude-agents/README.md`.

The pipeline agents own the engineering rules (isolated worktrees under `<repo>/.worktrees/`, the `fullstack-bug-fixing` five-phase process for bugs, never merging/deploying without review). They live in the agent definitions, not here.

**Exception — releases** run from the repo's main checkout by JP or an agent JP explicitly points at the release script: pause other agents, switch main to `main`, pull, run the script. Release scripts assume main-checkout paths and break inside worktrees. Every promotion PR into `main` of the scheduler or the quoting tool (full `staging`→`main` or a `release/*` cherry-pick) must include the `package.json` version bump (patch = fixes only, minor = feature/schema) and state the target `vX.Y.Z` in the PR title. After the prod deploy, check the `stamp-release` job and its audit summary in the deploy job's `$GITHUB_STEP_SUMMARY` and report anything left unstamped. `vX.Y.Z` milestones are write-once — never hand-edit one.

## Google integrations

Three accounts. Never mix them up, especially for email:
- **jp@benjis.com** (Benji's) — Claude.ai connector `mcp__claude_ai_*` (Gmail drafts only, Calendar, Drive) or the `gws` CLI.
- **jeanphilippe.moya@gmail.com** (personal; "my email") — googleapis via Bash, creds in `~/.claude/mcp-servers/gdrive-personal/`.
- **jp@casa-verde.ca** (Casa Verde) — googleapis via Bash, creds in `~/.claude/mcp-servers/gdrive-casa-verde/`.

Before any Gmail/Drive/Sheets call for personal or Casa Verde, read `~/.claude/mcp-servers/google-accounts.md` for the exact command, client IDs, and boilerplate. Never draft or send from jp@benjis.com for personal or Casa Verde matters, and never use the Claude.ai Gmail connector as a substitute.
