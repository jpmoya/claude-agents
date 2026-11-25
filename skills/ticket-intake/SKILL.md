---
name: ticket-intake
description: Use whenever JP asks for a ticket, bug, issue, story or task to be logged/filed/created/tracked, asks to add something to the backlog, or asks for something to be done through the pipeline/agents. The UserPromptSubmit hook hooks/ticket-intake-reminder.sh injects an instruction to run this skill first; hooks/ticket-intake-guard.sh refuses a bare `gh issue create` on the application repos. It runs the duplicate check, has product-manager file the ticket, puts it in a registered goal's GitHub Project and adds agent-go.
---

# Ticket intake (JP, 2026-11-18)

**Why.** No ticket JP asked for may sit in the backlog without the right project and the `agent-go` label. Two mechanical steps, always done by `skills/ticket-intake/ticket-intake.sh`, never by hand and never skipped:

1. the ticket joins a registered goal's GitHub Project (`gh project item-add <n> --owner <owner> --url <issue url>`), or is explicitly standalone (`none`);
2. the ticket gets `agent-go` (`gh issue edit <n> --add-label agent-go`).

Both are idempotent: re-running the helper on a ticket that already has them changes nothing.

## Step 0: is it a ticket request, and which repo?

The hook fires on wording, so it can be wrong ("close the ticket", "what is the issue with the deploy"). If JP did not ask for a ticket to be created, say so in one line and carry on with the real request. Otherwise find the target repo (from the conversation, the checkout, or the ticket's subject). If it is not clear and cannot be inferred, that is the one thing to ask.

**`jpmoya/claude-agents` is exempt (direct route).** Tickets in this repo never get `agent-go` and never join a goal or project (`DIRECT_ROUTE_REPOS`: launcher.sh refuses the repo, deliver.sh refuses a goal on it). Do step 1 (duplicate check) and step 3 (product-manager files it, for history), skip everything else, and implement it with subagents as CLAUDE.md says. The helper and the guard both leave this repo alone.

## Step 1: duplicate check, first

`~/.claude/skills/orchestrate/find-duplicates.sh <owner/repo> "<title>" "<key words>"` (exit 1 = strong candidate). If an existing ticket covers the request, **do not file a new one**: comment on or extend it, then run step 4 on that ticket (it still needs the project and agent-go). File only when every candidate is genuinely different, and then the body carries `Dup-check: reviewed #A, #B — differs because <reason>` (`hooks/dedupe-ticket-guard.sh` enforces it).

## Step 2: choose the project (exactly one short question, never silently skipped)

```
~/.claude/skills/ticket-intake/ticket-intake.sh goals <owner/repo>
```

lists the open registered goals whose scope is a GitHub Project and that cover the repo (`<owner>/<n>`, name, `go=true|false|unset`, URL). A project must belong to a registered goal: the helper refuses any other number.

- **No candidate:** the answer is `none`. Say so in the final line; do not ask.
- **One candidate that plainly fits the subject** (same repo and topic), or JP already named the project in his message: take it and state it in one line. Do not ask.
- **Two or more plausible, or one that might not fit:** ask exactly one question with `AskUserQuestion`: "Which project for this ticket?", options = each listed project (name + go=true/false) plus `none (standalone)`. `hooks/require-question-justification.sh` blocks the first attempt at any AskUserQuestion; this question is mandated by JP (2026-11-18, "which project"), so say that in the justification and re-ask once.
- **Standing feedback goals are not project-based** (`owner/repo:feedback`; their mirror projects are not a place to add tickets). A bug or request JP reports himself becomes `user-feedback` through product-manager and is picked up by the feedback goal anyway: when no listed project clearly fits, the answer is `none` (standalone), and agent-go is still added.
- **Business-Intelligence:** never an automatic agent-go (JP adds that one himself); the helper skips the label there. The project step still applies if a goal covers it.

## Step 3: file through product-manager

Never hand-write the ticket and never use an ad-hoc `general-purpose` subagent (CLAUDE.md "Who writes tickets"). Dispatch `product-manager` (Agent tool) with a brief that contains, as lines of their own:

```
Reported by: JP (directly)
Intake: project=<owner>/<n>        (or: Intake: project=none)
Dup-check: reviewed #A, #B — differs because <reason>     (only when step 1 found candidates)
```

and tell it to copy the `Intake:` and `Dup-check:` lines into the issue body. Both are checked by hooks at `gh issue create` time (`ticket-intake-guard.sh`, `dedupe-ticket-guard.sh`); a bare create on an application repo is refused with the exact fix. A history-only ticket that must NOT be picked up (for example a "bypass pipeline" hotfix already shipped, where agent-go would make the supervisor launch a duplicate run) uses `Intake: project=none go=no — <reason of a few words>`; the reason is mandatory and logged to `~/logs/pipeline/ticket-intake.log`.

## Step 4: do both steps with the helper

```
~/.claude/skills/ticket-intake/ticket-intake.sh finish <owner/repo> <issue#> --project <owner>/<n>      # or: --none
                                                                       # add: --no-go "<reason>" for a history-only ticket
```

Exit 0 = done (or already done); 2 = refused (not a registered goal's project; the registered choices are printed); 4 = a GitHub write failed (usually the token lacks the `project` scope: `gh auth refresh -s project`; re-run the same command, it finishes the job). Do this for every ticket the request produced, one command each.

## What agent-go means here (read before adding it)

- **Always added, whatever the goal's go.** A ticket in a go-true goal would inherit approval anyway; for a **go-false** goal or no goal, JP asking for the ticket to be logged is the instruction to work it, so `agent-go` is still added. Tickets in a goal are worked by the goal's delivery lead (the supervisor's shared dispatch skips goal tickets); standalone ones are dispatched by the supervisor.
- **agent-go is launch permission only.** It never answers a JP-only gate: production (merge, deploy, promotion), spending money, third-party systems of record, deleting data, external communications, where a private artefact is stored / who gets access, every infra prod `go`, mockup approvals, any change the app repo's `.github/release-routing.txt` routes to staging. Those gates still stop the run and still wait for JP's own `**[jp] GO**` / `**[jp] MOCKUPS APPROVED**`. Never post those on his behalf from this skill.
- **Not for the direct-route repo** (`jpmoya/claude-agents`) and **not for Business-Intelligence** (above).

## Final line to JP

One line, with the ticket number and a 3 to 5 word description: for example "#2751 (fix duplicate invoice total): added to CD release hardening, agent-go on." Nothing else unless something failed.
