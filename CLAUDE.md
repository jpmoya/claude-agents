# Cross-project conventions

## Software development

JP does not do hands-on engineering in the main session. Every code change in any of JP's repos — features, bug fixes, regressions, refactors — goes through the agent pipeline: file/refine the GitHub issue, then dispatch the `orchestrator` agent (see `~/.claude/agents/README.md` for the stage order). Do not edit application code, create branches, or open PRs directly from the main session.

Never add any file to a repo's `.claude/agents/` other than `deployer.md` — no repo-prefixed forks either. Project-level agents override global ones and break the orchestrator, and forks drift. Repo-specific rules belong in that repo's `CLAUDE.md`. See `~/dev/claude-agents/README.md`.

The pipeline agents own the engineering rules (isolated worktrees under `<repo>/.worktrees/`, the `fullstack-bug-fixing` five-phase process for bugs, never merging/deploying without review). They live in the agent definitions, not here.

**Exception — releases** run from the repo's main checkout by JP or an agent JP explicitly points at the release script: pause other agents, switch main to `main`, pull, run the script. Release scripts assume main-checkout paths and break inside worktrees.

## Google integrations

Three accounts. Never mix them up, especially for email:
- **jp@benjis.com** (Benji's) — Claude.ai connector `mcp__claude_ai_*` (Gmail drafts only, Calendar, Drive) or the `gws` CLI.
- **jeanphilippe.moya@gmail.com** (personal; "my email") — googleapis via Bash, creds in `~/.claude/mcp-servers/gdrive-personal/`.
- **jp@casa-verde.ca** (Casa Verde) — googleapis via Bash, creds in `~/.claude/mcp-servers/gdrive-casa-verde/`.

Before any Gmail/Drive/Sheets call for personal or Casa Verde, read `~/.claude/mcp-servers/google-accounts.md` for the exact command, client IDs, and boilerplate. Never draft or send from jp@benjis.com for personal or Casa Verde matters, and never use the Claude.ai Gmail connector as a substitute.
