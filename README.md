# claude-agents

JP's global Claude Code agent definitions, shared across machines (Mac + Clog VM).

- Live location on each machine: `~/.claude/agents` is a **symlink to this repo's checkout**.
- A `SessionStart` hook on each machine runs `git pull --ff-only` here, so every Claude session starts with the latest agents.
- To change an agent: edit here, commit, push. Other machines pick it up on their next session.
- **Name collisions:** a repo's `.claude/agents/` must never define an agent with the same name as one here (project-level agents override user-level ones with the same name, so a local `code-reviewer` silently replaces the pipeline one and stalls the orchestrator). Repo-local agents get a repo-prefixed name (e.g. `casa-verde-pm`); the one sanctioned exception is `deployer.md`, which the orchestrator looks for locally.

Pipeline: product-manager → ux-flow-designer (UI tickets: user flow — screens, states, copy) → ui-ux-designer (UI tickets: mockups of that flow, JP approval gate) ∥ solutions-architect (architecturally significant tickets) → fullstack-developer → code-reviewer + test-reviewer (parallel) → deployer (where the repo has one) or JP merges. `orchestrator` dispatches stages by reading `**[agent] MARKER**` comments on the GitHub issue.

