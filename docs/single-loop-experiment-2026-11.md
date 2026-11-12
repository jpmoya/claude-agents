# Single-loop agent vs. the multi-agent pipeline: assessment (Nov 2026)

Run 2026-11-09 to 2026-11-12. Outcome: the fast lane now runs as a single-loop runner (claude-agents #665, #674).

## Why we tested

A Gemini recommendation said single-loop agents (one session that plans, writes tests first, implements, runs tests, self-reviews) beat specialised hand-off pipelines. JP wanted evidence on our own tickets before changing anything, run in a "lab" that cannot touch production.

## Method

- **Single-loop arm:** one headless `claude -p` session on `claude-sonnet-5-5`, no sub-agents (`--disallowedTools Agent`), appended system prompt: plan, tests first for every acceptance criterion, implement, run tests/tsc/lint to green, critical self-review, commit locally. Run in an isolated clone with the git remote removed (no `gh`, no push). Extended-thinking budget was not set explicitly (Claude Code default).
- **Pipeline arm:** the real orchestrator chain (PM, test-writer, test-reviewer, fullstack-developer, code-reviewer, deployer, plus SA/UX where the lane required it).
- **Same inputs:** same base commit and same ticket text for both arms.
- **Scoring:** wall time and cost from the run metadata; tests/tsc/lint run by hand; one blind review per ticket by a fresh agent that saw only the ticket and two diffs labelled A/B (assignment randomised, key kept in a separate file). Reviewers did not run tests.
- **Lab isolation:** for #1875 the pipeline arm ran in a private copy of the repo (`jpmoya/lab-ops-tool-1875`, Actions disabled, workflow files stripped, one squashed baseline commit) with a duplicate ticket.

## Results

### Test 1: ops tool #1875, capture submitter name in feedback issues (full spec, backend)

| | Single loop | Pipeline (lab copy) |
|---|---|---|
| Wall time | 12.5 min | about 14 min of work after a 24 min queue wait |
| Cost | $0.45 | not logged |
| Diff | 4 files, +107/-5 | 5 files, +219/-3 |
| Checks | 114 feedback tests pass, tsc 0, lint config crashes (also without the change) | tsc 0; 114 pass; 5 failures in a workflow-file test, an artefact of stripping `.github/workflows` in the lab copy |
| Process | no rework | test-writer's first tests failed test-reviewer once and were rewritten |

Blind review: **tie**, slight edge to single loop on correctness (captures thrown as well as returned errors, as the ticket's observability section asks), slight edge to pipeline on test depth. Deployer step blocked as expected (lab repo is not a deploy project).

### Test 2: sales tool #1259, per-quote tax (HST / BC GST+PST) sent to QuickBooks (large, migration + money)

| | Single loop | Pipeline (real run) |
|---|---|---|
| Active time | 11 min | 46 min to first review pass; roughly 2.5 h with CI-red fix rounds; about 8.5 h wall to staging because of CI queue stalls |
| Cost | $1.74 | not logged; about 20 agent runs |
| Diff | 19 files, +654/-8 | larger (about 1,190 diff lines vs about 930) |
| Checks | tests/tsc/lint pass; 15 proposal-PDF tests failed on a sandbox Chromium problem | CI red on first attempt (migration-lint: destructive and additive DDL in one file; "no real numbers committed" test), fixed over several rounds |

Blind review: **single loop narrowly better**. It reused existing patterns, kept the diff tighter, applied the tax code in one pass and captured errors on both push and deposit paths; the pipeline version had more tests (about 47 vs 23) and stricter address parsing but added unrequested docs and import churn.

### Test 3: ops tool #2373, hide Partner/Add-on services and Explore tab in client portal (express agent: ticket writing included)

| | Express (single agent, wrote its own ticket) | Pipeline (shipped PR #2376) |
|---|---|---|
| Time | 15 min | 28 min active (including a mockup gate), then CI waits to staging |
| Cost | $0.52 | not logged |
| Diff | 9 files, +53/-41 | 16 files, +236/-3 |

Blind review: **pipeline clearly better**. Express returned a 404 where the ticket required a redirect, named the flag differently from the spec, rewrote or deleted existing tests instead of forcing the flag true, and only tested the hidden state. Caveat: the express agent only had a one-line report, while the pipeline's PM had written a detailed ticket, so this measures the value of the spec stage as much as the build stage.

### Test 4: ops tool #2431, tech app-required page shows full nav (express, no baseline)

12 min, $0.35, 3 files, +63/-3, ticket and PR text written by the agent. Not compared: no pipeline baseline exists (ticket was still open) and no pipeline arm was run. Not yet reviewed.

## Cost and time summary

| Ticket | Single / express | Pipeline, active work |
|---|---|---|
| #1875 | 12.5 min, $0.45 | about 14 min |
| #1259 | 11 min, $1.74 | 46 min first pass, about 2.5 h with fixes |
| #2373 | 15 min, $0.52 | 28 min |
| #2431 | 12 min, $0.35 | none |

Pipeline cost per run is not recorded anywhere, so "cheaper" is likely (1 session vs about 6, 7 and 20 agent runs) but not measured.

## Conclusions

1. With a PM-written spec, one agent doing test-first, implement, run checks and self-review matched the multi-stage pipeline in quality on both well-specified tickets (one tie, one narrow win), and was about 2 to 4 times faster on active work.
2. The spec stage is where the value is. The one ticket where the agent wrote its own spec lost clearly. Keep the PM stage; collapse test-writer, test-reviewer, developer and narrow review.
3. Caveats: three data points, one blind reviewer per ticket and it is a model, the single loop never faced real CI (the #1259 pipeline run lost hours there), the reviewer did not run tests, and pipeline cost was not measured.

## Change made

claude-agents #665 (and #674, page prose): on the fast lane (`Lane: fast` from the PM, or the `fast-lane` label unless the PM writes `Lane: full` with a reason) `fullstack-developer` runs as a single-loop runner: plan, failing regression test first, minimal implementation, tests/tsc/lint to green, self-review, re-run, then PR with the green-run evidence in IMPLEMENTED. The narrow test-reviewer round is dropped on the fast lane; `code-reviewer` stays as the one independent check; the deployer and the full lane are unchanged. Out-of-scope changes (migration, new endpoint, risky list) are rejected back to needs-spec rather than pushed through.

## Incidents during the experiment

- The real orchestrator was launched on the production ticket #1875 before the lab-only instruction landed. It was stopped; 4 pipeline comments (supervisor claim, tests written, tests fail, test defect) remain on the real ticket because the auto-mode safety check blocked deleting them. A local worktree it created in the ops-tool checkout also remains.
- The auto-mode classifier blocked launching a second autonomous session until the session was switched out of auto mode.
- The #665 subagent briefly committed to local `main` when something switched its branch; nothing reached `origin/main`.

## Suggested next steps

- Review the #2431 express result against a pipeline run (needs a PM-written ticket) to test the "PM spec + single loop" hybrid directly.
- Record per-run token cost for pipeline stages so the cost comparison can be measured.
- Add 2 to 3 more fast-lane tickets (a bug fix and a UI one) before widening the single loop beyond the fast lane.
- Revisit extended-thinking settings (the experiment used the default).
