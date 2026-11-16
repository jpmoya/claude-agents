---
name: pm-goal-assignment
description: Use whenever the product-manager creates or refines a ticket. Every ticket belongs to exactly one delivery goal; the launcher resolves the goal before the PM starts and passes it as a `Goal: <goal id>` line. This skill says how to read that line, bind the ticket to the goal (label, milestone or feedback label) and record `Goal:` in the body. The PM never asks anyone; no Goal line means refuse and exit.
---

# PM goal assignment

Every ticket the PM creates or refines is bound to one goal (a registry entry listed by `deliver.sh status`). JP: "every time they create a ticket they have to assign it to one of the goals; if it's not 100% obvious which one then ask JP when he asks the ticket to be logged ... make it a requirement to start the PM agent."

## 1. Start requirement (the PM never asks)

The launch prompt must carry a line `Goal: <goal id>` or `Goal: none-confirmed-by-JP`.

- **No such line: print exactly one line** (`product-manager: refusing to start: no 'Goal: <goal id>' line in the launch prompt; the launcher must resolve the goal first`) **and exit.** No `gh` calls, no comment, no question. `stage-run.sh` and `skills/orchestrate/pm-goal.sh require` refuse the same way before the process even starts.
- `none-confirmed-by-JP` is valid only because the launcher asked JP and he said the ticket belongs to no goal. The PM never writes it on its own.

## 2. The launcher resolves the goal (before the PM starts)

Whoever starts the PM (interactive session, `message-triage`, the supervisor's spec run, the orchestrator) does this first:

1. List live goals: `~/.claude/skills/orchestrate/deliver.sh status` (column 1 is the goal id; live = `queued`, `active`, `held`, `waiting_jp`). Goal kinds: `owner/repo:milestone:<n|title>`, `owner/repo:milestones:all`, `owner/repo:feedback`, `owner/repo#N`, `label:goal: <title>` (cross-repo).
2. Match the ticket by repo, then milestone, label or topic:
   - user-feedback ticket (staff report) with no other covering goal: the repo's feedback goal (`pm-goal.sh feedback <owner/repo>` prints its id);
   - ticket whose topic is the title/scope of a milestone or label goal in that repo: that goal;
   - an existing ticket that already has a `Goal:` line, a `goal: <title>` label or a live-goal milestone keeps it (`pm-goal.sh ticket <owner/repo> <N>`).
3. **Only when exactly one goal fits and nothing else could be argued: that is "100% obvious", pass it.** Otherwise ask JP, in the same message where he asked for the ticket (a short list of the candidate goals plus "none"). Do not start the PM until he answers; his answer is the `Goal:` line (`none-confirmed-by-JP` if he says none).
4. Pass `Goal: <id>` as its own line in the PM prompt.

Never guess to avoid the question, and never pass `none-confirmed-by-JP` on JP's behalf.

## 3. Binding the ticket (what the PM does with the Goal line)

Bind the way existing goal tickets carry it (see `goal-lib.sh`: `goal_scope`, `goal_label_name`):

| Goal kind | Binding |
|---|---|
| `...-fb-feedback` (staff feedback) | `user-feedback` label plus the normal milestone from the milestone fit check. No goal label, no project item (this is how benjis-ops-tool #2657, the Crew Chat mentions ticket, is bound). |
| `...-ms-<n>` / `milestone:<n\|title>` | Put the ticket in that milestone (`gh issue edit <N> --milestone "<title>"`). It overrides the milestone fit check. |
| `...-ms-all` / `milestones:all` | Any open milestone of the repo; use the normal fit check. |
| `label-goal__...` (cross-repo) | Add the label `goal: <short title>` (the exact name, see `goal_label_name`; create it with colour `5319e7` if the repo lacks it) in every repo the ticket lives in, only repos listed in the goal. |
| `...-t-<N>` (single ticket) | A new ticket cannot join it; treat a request to join as a dependency follow-up of #N (`Parent:` line) and use #N's goal. |
| `none-confirmed-by-JP` | No binding. |

Gotcha: a ticket bound to a feedback or label goal must NOT get a milestone that is itself a live milestone goal. The feedback goal yields every ticket another live goal covers, so the ticket would silently change goals. Pick a milestone no live milestone goal owns.

Then add a body line `Goal: <goal id>` near the top (same line the launch prompt carried; on an existing ticket add it only if missing, and keep any existing binding). When the duplicate check finds a pre-existing ticket, bind that ticket instead of filing a new one.

The `Goal:` body line is bookkeeping for the PM and the orchestrator; it does not replace the label/milestone binding above, and it never grants `agent-go` (the approval rules in `agents/product-manager.md` are unchanged).
