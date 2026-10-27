# Living Document — claude-agents

Agent-readable session log. Newest first. Terse by design — see the `living` skill for format.

---

## 2026-10-27 — direct-report-label-fix

SHIP: PR #503 (issue #501) — merged, squash. Briefs for a JP-reported bug now must carry a `Reported by: JP (directly)` line so product-manager's existing direct-report rule (added by #498) can fire and add `user-feedback`.
DEC: fix at the brief-writing layer (CLAUDE.md "Who writes tickets" + product-manager.md "Applies to"), not a new mechanism — adjudicator verdict was CHANGE? YES, net new mechanisms = 0.
FIND: incident benjis-ops-tool#1934 (tech can't undo an auto-missed visit after day-unlock) was filed by product-manager with no `user-feedback` label even though the #498 rule already existed. Root cause: the rule only fires when the brief states JP reported it; the dispatching session's brief said "Confirmed in production Sentry" and never said "JP", so the PM read it as a Sentry/investigation finding (the case the rule excludes), not a direct report. Counter-case: benjis-sales-tool#1142's PM did add the label from an equally thin brief — same rule, different reads, PM reasoning not recorded (thinking blocks len=0).
FIND: SCHEDULER-1D (the Sentry event behind #1934, UNDO_AFTER_CHECK_IN_ERROR) was already in Sentry since 2026-10-25, 2 occurrences, level=warning (captured deliberately by `captureRejectedTechSave`, #1258 pattern — expected-refusal logging, not an error alert). Never crossed the Sentry→GitHub `source:sentry` poller's alert threshold, so intake never saw it; a human had to notice the pattern and report it.
FILES:
- CLAUDE.md — "Who writes tickets" section gains one sentence: state `Reported by: JP (directly)` in the brief when applicable.
- agents/product-manager.md — "Applies to" bullet for the user-feedback rule now also recognizes that line, and states Sentry/other-agent corroboration never overrides the JP-origin label.
LESSON: a rule that depends on the dispatching session correctly signaling intent in a free-text brief is fragile — the same PM gave two different answers to two similarly-thin briefs. Prefer a structured marker (`Reported by: JP (directly)`) over trusting the agent to infer origin from prose.
