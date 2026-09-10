# Agent Pipeline

These agents form JP's automated software engineering pipeline. The **orchestrator** reads marker comments on GitHub issues and dispatches the right agent at each stage. No agent makes product or merge decisions — JP owns those.

## Default pipeline (full lane)

product-manager → test-writer → test-reviewer → fullstack-developer → code-reviewer + test-reviewer (narrow) → deployer

## Opt-in stages

- **solutions-architect** — dispatched only when the PM posts `READY FOR ARCHITECTURE` or JP comments `add SA`. Default is to skip.
- **ux-flow-designer** — dispatched only when the PM includes `UX flow: yes` or JP comments `add UX flow`. Default is to skip.
- **ui-ux-designer** — runs on `UI change: yes` tickets, with or without a prior user flow.

## Fast lane

Bug fixes and small changes: product-manager → fullstack-developer (writes its own regression test) → code-reviewer + test-reviewer (narrow) → deployer.

## Infra track

Issues labelled `infra`: infra-planner → infra-reviewer → infra-operator (prod steps gated on JP's `go`).

## Model and effort assignments

| Agent | Model | Effort |
|---|---|---|
| orchestrator | sonnet | medium |
| product-manager | (default) | (default) |
| ux-flow-designer | opus | medium |
| solutions-architect | opus | medium |
| ui-ux-designer | sonnet | medium |
| test-writer | sonnet | medium |
| test-reviewer | sonnet | medium |
| fullstack-developer | (default) | (default) |
| code-reviewer | haiku | medium |
| deployer | sonnet | medium |
| infra-planner | (default) | (default) |
| infra-reviewer | (default) | (default) |
| infra-operator | (default) | (default) |
| design-research | (default) | (default) |

## Rules

- Never add agents to any repo's `.claude/agents/` other than `deployer.md`. Project-level agents override globals and break the orchestrator.
- Repo-specific rules belong in that repo's `CLAUDE.md`, not in agent definitions.
- All agents keep issue comments brief: facts, verdict, next action.
