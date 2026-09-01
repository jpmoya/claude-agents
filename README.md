# claude-agents

JP's global Claude Code agent definitions, shared across machines (Mac + Clog VM).

- Live location on each machine: `~/.claude/agents` is a **symlink to this repo's checkout**.
- A `SessionStart` hook on each machine runs `git pull --ff-only` here, so every Claude session starts with the latest agents.
- To change an agent: edit here, commit, push. Other machines pick it up on their next session.

Pipeline: product-manager → fullstack-developer → code-reviewer + test-reviewer (parallel) → JP merges. `orchestrator` dispatches stages by reading `**[agent] MARKER**` comments on the GitHub issue.
