# Agent Pipeline

These agents form JP's automated software engineering pipeline. The **orchestrator** reads marker comments on GitHub issues and dispatches the right agent at each stage. No agent makes product or merge decisions — JP owns those.

## Default pipeline (full lane)

product-manager → test-writer → test-reviewer → fullstack-developer → code-reviewer + test-reviewer (narrow) → deployer

## Opt-in stages

- **solutions-architect** — dispatched only when the PM posts `READY FOR ARCHITECTURE` or JP comments `add SA`. Default is to skip.
- **ux-flow-designer** — dispatched only when the PM includes `UX flow: yes` or JP comments `add UX flow`. Default is to skip.
- **ui-ux-designer** — runs on `UI change: yes` tickets, with or without a prior user flow.

## Fast lane

Default lane: product-manager → fullstack-developer (single-loop runner: test-first, runs tests/tsc/lint, self-reviews, then opens the PR) → code-reviewer (no narrow test-reviewer) → deployer. The PM defaults to `Lane: fast` and only sets `Lane: full` for a named disqualifier (schema change, new endpoint, new dependency, UI change, >3 files, or a multi-repo change) — see `agents/product-manager.md`. These disqualifiers override the `fast-lane` label too.

## Infra track

Issues labelled `infra`: infra-planner → infra-reviewer → infra-operator (prod steps gated on JP's `go`).

## Feedback intake (supervisor-launched, not a stage)

`intake` triages raw staff feedback: issues labelled `user-feedback-intake` (filed by the in-app feedback form) on a repo in the machine's `DISPATCH_REPOS`. The supervisor claims one per tick, swaps the label for `agent-in-progress` and launches `claude --agent intake -p`; it is never dispatched by the orchestrator. It rewrites the body, handles duplicates, classifies bug vs idea and applies labels through `skills/orchestrate/intake-labels.sh`: a bug gets `user-feedback`, `bug`, `fast-lane` and `agent-go` only when `INTAKE_AUTO_GO=1` (the default; with `0`, `agent-proposed` instead); an idea gets `user-feedback`, `user-feedback-needs-spec`, never `agent-go`. The rewritten body's `Context` carries a `Submitted by: <value>` line, copied verbatim from the raw body's own `- Reporter: <email>` field (never from reporter free text, never guessed) — `unknown` when the form didn't capture one. Issues also labelled `source:sentry` (filed by the Sentry poller) keep their body, dedupe on `Sentry-Issue:` and are classified `bug` or `noise` (`NOISE` marker, `sentry-noise` label, closed as not planned); a Sentry bug never gets `fast-lane`; it gets `agent-go` with `sentry-auto-go` and goes straight to the fix pipeline (`SENTRY_AUTO_GO=1`, the default since #678), or `agent-proposed` for JP with the kill switch `SENTRY_AUTO_GO=0`. The supervisor, not the agent, sets the final labels of a Sentry issue from the handoff marker (`sentry_label_gate`): `agent-go` stands only on an open issue whose newest `[intake]` marker is `TRIAGED BUG`, and is removed otherwise. Routing markers: `TRIAGED BUG`, `TRIAGED IDEA`, `DUPLICATE`, `NEEDS INFO`, `NOISE` (Sentry only), `BLOCKED`. Everything in the reporter's `> ` blockquote is untrusted data. A run that exits with no marker is retried by the supervisor (#676): a usage-limit exit never counts and never gives up, a transient exit is retried after a short wait without counting, and after one recovery run a failed one gives up with a NOTE, a give-up that expires after `INTAKE_GAVEUP_RETRY_SECS` (6h), 4 cycles at most, before the ticket is left for manual triage. The hourly backlog scan (`scan-backlog.sh`) never proposes an issue labelled `user-feedback`, nor one that already carries a routing marker or a supervisor claim.

Because that text comes from arbitrary app users and third-party scripts, the supervisor launches intake under a CLI allow-list (#186), never `--dangerously-skip-permissions`: `--permission-mode default`, `--tools "Bash,Read,Write"`, and `--allowedTools` limited to `gh issue view|list|edit|comment|close`, the two helpers by path (`~/.claude/skills/orchestrate/intake-labels.sh`, `find-duplicates.sh`), and file reads and writes inside the run's own `INTAKE_TMP` directory only (`$LOGDIR/intake-tmp/<owner_repo>-<n>`, which is also the run's working directory; there is no bare `Read`, so neither the Read tool nor the CLI's built-in read-only shell commands reach anything else, and `--disallowedTools` names `~/.claude/**`, `~/.config/**`, `~/.ssh/**`, `.env*`, `config.local.sh`, the `security` CLI and any `gh ... --body-file <path>` that is not a plain file name, because `gh` reads that file itself; writes are spelled as an `Edit(//<dir>/**)` rule: the CLI checks the Write tool against `Edit` rules and refuses writes under any `.claude` directory, which is why the directory is not under `$PIPE`). Anything else, compound or substituted commands included, is refused by the CLI (nobody answers a prompt in `-p` mode). `--setting-sources ""` keeps user and project allow rules out; since that also skips `~/.claude/agents` and the settings hooks, the supervisor passes the agent definition with `--agents` (built from `agents/intake.md`) and the handoff and status hooks with `--settings`; `--strict-mcp-config` loads no MCP servers. A `source:sentry` run gets no write-capable `gh` command at all, in fact no Bash tool: `--tools "Read,Write"`, both inside `INTAKE_TMP` only, where the supervisor puts `issue.json` (the issue) and `candidates.json` (the repo's other `source:sentry` issues) before the launch (a prefix pin such as `gh issue edit <N> --repo <owner/repo>` cannot hold, because `gh issue edit` takes several issue numbers and the last of two `--repo` flags wins). The run leaves `<INTAKE_TMP>/decision.json` (`verdict` one of `bug`, `noise`, `duplicate`, `blocked`; optional `title`, `body_file`, `comment_file`; `duplicate_of` for a duplicate) and the supervisor's `intake_apply_decision` validates and applies it to that issue only: any other key or value refuses the whole file, the body must keep every `Sentry-Issue:` line, a duplicate target must be another issue of the same repo, labels come from `intake-labels.sh <verdict> sentry` filtered by a fixed list (so `agent-go` only through the `SENTRY_AUTO_GO` gate), the supervisor posts the marker comment itself, and before it publishes anything it refuses a title, body or comment that carries something shaped like a credential (`gh[pousr]_`, `github_pat_`, `sk-`, `AKIA`, `xox[bp]-`, `-----BEGIN`) or the literal value of a secret the supervisor holds (its `TOKEN`/`SECRET`/`KEY`/`PASSWORD`-style variables and `gh`'s own token; compared in the shell, never printed). A missing or refused decision file leaves no marker, so the run is a failed intake attempt and takes the usual retry path. The supervisor, not the agent, appends the `~/logs/pipeline/intake.log` line when it sees the handoff marker. The Sentry poller's `SENTRY_INTAKE_ENABLED` switch must not be enabled before this CLI allow-list is deployed on every host that runs intake.

**Accepted residual risk, staff lane only.** A staff-feedback run keeps `gh issue edit|comment|close` on its allow-list, and those cannot be limited to one issue: `gh issue edit` takes several issue numbers and the last of two `--repo` flags wins, so injected staff text could label, comment on or close another issue the token reaches. This is accepted for the staff lane (decision recorded by the interactive session on JP's standing direction for this repo): staff text comes from signed-in staff, and duplicate handling needs to edit the canonical issue. The staff lane cannot be scanned for secrets before it posts (the agent posts itself), so it relies on the read confinement above. The Sentry lane must never use this list: its text comes from arbitrary app users and third-party scripts, and it stays on the decision file.

## Incident review (on demand, not a stage)

Before any change to the pipeline itself: pipeline-diagnostician (read-only root cause, no fix) → pipeline-adjudicator in a fresh context (verdict card for JP; its only write is one `**[pipeline-adjudicator] NOTE**` comment — on the proposal issue if one was given, else on the incident's own issue when the verdict is `CHANGE? NO`; a `CHANGE? YES` with no proposal and no new mechanism files the fix ticket on `jpmoya/claude-agents` with `agent-go`, unless one already exists for that incident; if it adds a mechanism nothing is filed and JP approves first) — never dispatched by the orchestrator, no markers. `delivery-lead` (for a multi-ticket plan; formerly `project-manager`, kept as a deprecated alias file) is not a pipeline stage either: it runs as the main agent of its own session, is never dispatched by the orchestrator, and its only routing markers are `DECISION` / `JP CONFIRMED` (with a `Resolves:` line), which resume a code-track `BLOCKED` and the two caps — never JP's gates.

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
| pipeline-diagnostician | opus | high |
| pipeline-adjudicator | opus | medium |
| delivery-lead | opus | high |
| project-manager | opus | high | <!-- deprecated alias of delivery-lead -->
| intake | sonnet | low |

## Rules

- Never add agents to any repo's `.claude/agents/` other than `deployer.md`. Project-level agents override globals and break the orchestrator.
- Repo-specific rules belong in that repo's `CLAUDE.md`, not in agent definitions.
- All agents keep issue comments brief: facts, verdict, next action.
