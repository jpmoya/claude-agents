# Pipeline audit, 2026-11-18

Question behind it: JP keeps having to ask "why isn't X progressing faster?". This audit ranks the brittle parts of
the pipeline, lists what JP cannot see, counts the tickets that are falling between the cracks right now, and records
what was fixed directly (this repo is direct-route) and what is left for JP.

Evidence sources: `~/logs/pipeline/supervisor.log` and `events.jsonl` on the Mac and the VM (`ssh clog-exec`), local run
state (`~/.claude/pipeline/state`), `goalqueue.json`, both hosts' `config.local.sh` (secrets not read), the code on
`origin/main` at `e2240c7`, and one GraphQL snapshot of every open issue and PR in benjis-ops-tool, benjis-sales-tool
and claude-agents (taken 2026-11-18 ~22:30Z; REST core was at 533/5000, so the audit used GraphQL and local git only).
All counts are read-only measurements at that moment.

## 1. Corrections to the brief

| Brief item | What the evidence says |
|---|---|
| (a) one queued ticket per tick | Confirmed, and it is the biggest throughput loss of the day (section 2). |
| (e) feedback goals lost their slot exemption | Not live now: both feedback goals in `goalqueue.json` still have specs ending `:feedback`; PR #760 (project-only goals) keeps that spec. |
| (l) stale DISPATCH_REPOS | Already cleaned on the Mac at 19:05Z (`config.local.sh.bak-20261118` diff: casa-verde-site, rfp_finder, Business-Intelligence removed). 320 "no local checkout" lines before that. |
| (m) launch and queue print the same "check" line | Not on main: the queue path prints `queued #N ... check: orchestrate.sh queue`, the launch path `launched ... check: orchestrate.sh status`. The real failure is that callers sent the output to /dev/null and both paths exit 0. Exit codes were left alone (goal launchers treat non-zero as failure). |

## 2. Tonight's main stall, measured

Mac, 14:03Z to 16:38Z: 15 queue drains, one per tick, each tick 6 to 16 minutes apart, while 1 to 4 of 7 slots were busy:

```
14:03 #2543 4/7   14:19 #2544 3/7   14:28 #595 4/7   15:05 #699 3/7   15:12 #1477 2/7
15:20 #2710 1/7   15:31 #2641 2/7   15:37 #2696 2/7  15:52 #2699 3/7  16:06 #2728 2/7
16:15 #1436 2/7   16:20 #1474 2/7   16:26 #705 2/7   16:32 #2730 3/7  16:38 #2723 4/7
```

Queue waits (events.jsonl `run_launch.queue_wait_s`) climbed from 48 s to 8599 s (2 h 23 min). Memory was 2.7 to 4.2 GB
free against a 1.2 GB floor, so capacity was never the limit; the one-per-tick rule (`supervisor.sh` step 2, header
"One launch per tick max") was.

Why ticks are slow (Mac, tick = `gh-quota remaining` line to the next one): most ticks take 0 to 5 minutes, but 13:10
to 15:49 had 16, 17, 11, 33, 9, 13 and 12 minute ticks. In the 33-minute tick (14:27) the drain launched at 14:28 and the
goal step (3d) then ran until 14:58: a comments read that failed with "error connecting to api.github.com" held it 6
minutes, the sentry-skip scan and a project scope check another 17. The launchd/cron timer fires every 2 minutes but the
tick lock (`flock`) skips overlapping ticks, so a slow goal step directly divides drain throughput. The VM's ticks were
2 to 8 minutes all evening.

## 3. Most brittle parts, ranked (blast radius x likelihood)

1. **Queue drain is one launch per tick, and ticks are long.** `supervisor.sh` step 2 (`# 2. Drain queue (one item per
   tick ...)`). Blast radius: every queued ticket on a host. Likelihood: every burst (goal leads and hand launches queue
   whenever a slot is briefly full). Evidence: section 2. **Fixed** (section 6).
2. **No alert reaches anyone.** Neither host sets `SLACK_WEBHOOK_URL` or `SLACK_ENGINEERING_CHANNEL` (JP turned the
   #engineering posts off on 2026-09-30 for noise). `autoretry_alert`, `sw_alert`, `claim_alert`, `launch_alert`,
   `code_sync_alert`, `goal_queue_fail` and every `notify_engineering` call return early. `grep -c '\[slack\]'` is 0 in
   every supervisor log on both hosts. Every stall tonight was visible only as a log line. Blast radius: all of them.
   Left for JP (where alerts go is his call); see section 5.
3. **Held runs never resume on their own after JP or a delivery lead answers.** Step 1 skips every `.held` run; step 1b
   only re-checks machine-clearable BLOCKED classes, start-gates and the loop-cap decision path. A `[jp] GO`,
   `[jp] SKIP MOCKUPS`, `[jp] MOCKUPS APPROVED` or `[delivery-lead] DECISION` posted after a JP-gate or needs-JP BLOCKED
   hold is read by nothing until someone relaunches by hand. The hold alert tells JP to "re-add agent-go", which does
   nothing while `SHARED_DISPATCH_ENABLED=0` unless a live goal covers the ticket. Now: 10 held runs whose newest marker
   is a GO or a DECISION (5 each). Left for JP (section 7).
4. **The goal queue fails closed on one bad entry.** `_GOAL_QUEUE_SERIAL_JQ` (`goal-lib.sh` ~1655): `$busy` is true if
   any registry goal is `unreadable`, so no queued goal starts. A project goal whose GitHub project is closed did this to
   Sales Workflow 3.0 tonight. With `GOAL_SERIAL=1` this is a single point of failure for both hosts. Visibility is
   #762 (status page: show goal stalling queue); the behaviour change (skip instead of block) is a design call.
5. **Labels drift from run state with no signal.** `agent-go` is consumed at claim (`orchestrate.sh`), step 3 clears
   `agent-in-progress` when a run is held, dead or done, and step 4 clears it on any ticket with no local state and a
   30-minute-old last comment (`supervisor.sh` ~2286). Nothing puts `agent-go` back. Result: a ticket in no state any
   automation reads (the #1488 "lost ticket"). Now: 85 open tickets carry a non-terminal pipeline marker and no pipeline
   label; 60 of them are in no live goal (section 4).
6. **The slot holder goal is not preempted and an idle hand-off defers the goal.** `GOAL_SERIAL=1`: Sales Workflow 3.0
   (priority 1) waits behind `proj-jpmoya_41` (priority 4) because priority only orders the queue, it does not take
   the slot. A goal that hands off idle gets `deferred_at` and sorts behind every other queued goal (`goal_requeue`,
   okey). Design, left for JP; #760 adds the explicit `go` flag that prevents the "go true, nothing granted" case.
7. **Sentry cap and sentry skip.** `SENTRY_AUTO_GO_DAILY_CAP=3` per host per repo refuses even a CI-critical ticket
   (#2751 auto-release verdict, still waiting with agent-go); goals skip `source:sentry` tickets unless
   `--include-sentry` (5 ops tickets skipped every goal tick). Spend cap: JP's call.
8. **The stale-shell killer in `hooks/limit-shells.sh` behaves differently per host.** It kills any process matching
   `claude.*bash` older than 10 minutes, globally, on every Bash call of every session. On the VM (`ps -o etimes` works)
   that includes any tool shell of any session (`/home/claude/.claude/shell-snapshots/snapshot-bash-...` matches), so
   one session's hook can kill another session's long test run or a stage's long command. On the Mac `etimes` is not a
   `ps` keyword, so the killer silently does nothing. No kill was proven tonight; the 5-per-session cap also blocks the
   interactive session from checking state while its own subagents run (brief item k). Left for JP (limits are a
   resource call).
9. **Mac/VM config divergence.** Mac `MAX_CONCURRENT=7` with `MAX_CLAUDE_PROCS=16`, below config.sh's own rule
   (3 x 7 - 1 + 2 = 22); VM `MAX_CONCURRENT=5`, `MAX_GOALS=3`, `MEM_FLOOR_MB=1800`. Both `SHARED_DISPATCH_ENABLED=0`.
   The Mac is a laptop: network drops (12:39Z, 14:28Z "error connecting to api.github.com") stretch its ticks and it
   dispatches only ops/sales.
10. **GitHub budget shared with everything.** REST core was 533/5000 during this audit; below 1500 the supervisors skip
    optional work (status reconcile, stale digest, worktree sweep), below 300 they only restart. One interactive
    session's polling starves both supervisors.
11. **Small bug: `gh-budget.sh:224`** builds a sed expression from `owner/repo`, so `s/ owner/repo / /` fails ("bad flag
    in substitute command", 28 lines today) and empties the synced-repo set. It fails safe (more API reads, no stale
    data). **Fixed** (section 6).

Parsing by regex of comments is everywhere (latest_marker, blocked_class_of, claim_winner, goal_ticket_state) but it is
consistent (one vocabulary in `hooks/pipeline-markers.sh`) and no misparse was seen tonight; not ranked.

## 4. Falling between the cracks, counted now

Snapshot: 205 open ops issues, 126 sales, 58 claude-agents. "Live goal" = a label or open project bound to an open
registry goal (projects 37, 40, 41, 44, label `goal: Sales Workflow 3.0`) or a `user-feedback` ticket (feedback goals).
Local state = both hosts' `~/.claude/pipeline/state`.

| Crack | Detection | Count now |
|---|---|---|
| Ticket in no automated state (non-terminal pipeline marker, no agent-go / agent-in-progress / agent-proposed / intake / needs-spec label) | GraphQL issues + last 25 comments, marker regex `^\*\*\[agent\] MARKER\*\*` | **85** (60 outside any live goal) |
| ...of which the newest marker says work can continue (GO, SKIP MOCKUPS, DECISION, IMPLEMENTED, READY FOR ENGINEERING, TESTS WRITTEN, TEST DEFECT, PASS, PLAN READY, APPLIED) | same | **47** (37 outside a live goal; 22 held locally; 11 older than 7 days) |
| ...of which the newest marker is a BLOCKED / AWAITING GO / PROMOTION HELD (owner: JP or a lead) | same | **38** |
| Held run whose newest marker is a JP GO (JP answered, nothing resumed it) | local `.held` + newest marker | **5** |
| Held run whose newest marker is a delivery-lead DECISION | same | **5** |
| agent-go sitting with no run | label set, no agent-in-progress | **4** (ops #2751 auto-release verdict fix: sentry-capped; sales #384 Copper back-creation script: no goal; sales #1436 legal name, #1489 QBO auto-link: newest marker BLOCKED) |
| agent-in-progress with no live run or queue entry on either host | label + local state | **1** (sales #1488 hide QBO buttons, being relaunched) |
| Deployer said DEPLOYED, ticket still open | last marker DEPLOYED / DEPLOYED TO STAGING | **37**: 8 already on main (ticket should be closed), 29 on staging only (not released) |
| Staging ahead of main | `git rev-list --count origin/main..origin/staging` | ops **39** commits, sales **316** commits |
| Open PR with failing CI or a merge conflict | GraphQL `statusCheckRollup`, `mergeable` | **8 of 11** (ops #2540, #2658, #2733, #2752, release PRs #2754 and #2760 to main failing; sales #716, #730) |
| Direct-route repo ticket carrying agent-go (nothing will ever run it) | claude-agents label | **4** (#463 lock hook git add, #478 shell limiter Monitor, #513 markers() NOTE filter, #516 deployer required-checks; idle 12 to 26 days) |
| Goal deferred behind a lower-priority slot holder | `goalqueue.json` | **1** (Sales Workflow 3.0, priority 1, deferred 20:00Z, behind `proj-jpmoya_41` priority 4) |
| Goal blocked by an unreadable registry entry | `goalqueue.json` | 0 now (was the Workflow 3.0 stall earlier tonight) |
| Bare backlog (no pipeline label, no marker, no live goal) | same snapshot | 1 (sales #1430 contract template v2.5) |

Caveats: the marker regex reads the last 25 comments only; "released" uses origin/main commit subjects and merge
ancestry (a squashed promotion with no `(#N)` reads as not released, see brief item f).

## 5. What JP needs to see: one "where is it stuck and why" view

Per ticket, one row with exactly one of these states, computed from data that already exists:

| State | Source that already has it |
|---|---|
| Running: stage, host, minutes in stage | pid files, `_rs_live_stage`, `events.jsonl` stage_start |
| Queued: position, wait so far, host, slots used/total | `queue/*.json` queued_at, `count_running`, MAX_CONCURRENT |
| Waiting for the goal slot: which goal holds it | `goalqueue.json` slot + queued |
| Waiting on JP: what, since when | `.held` + `.alert` text, gate marker |
| Waiting on a delivery lead: which goal, is its lead alive | `.held`, goal pid, `goal-<id>.json` |
| Auto-retry pending: class, attempts left, next check | `.autoretry`, `.autoretry-check` mtime |
| No owner: marker says continue but nothing will pick it up | the section 4 query |
| Merged to staging, not released / released, ticket open | deployer marker + `git` against origin/main |

Per goal: slot holder or queue position, why it is not starting (unreadable entry, deferred, cooling, host-confined,
Mac on battery: `goal-paused`), last progress time, lead alive.

Signals that exist but are not on the status page: queue position and wait (`queue_wait_s` in events.jsonl), the drain
count per tick, `[goal] error:` lines, `goalq-lost-*` / `goalq-alerted-*` files, the stale-work digest (log only),
`.alert` text for held runs, the code-sync alert file, `gh-quota` tier, `[reconcile] cleared orphaned` events (the moment a
ticket becomes lost).

One alert per stall tonight:
- Slots idle while the queue is non-empty for more than 10 minutes (would have caught (a)).
- A ticket whose newest marker is "continue" and that has no label, run or queue entry for more than 1 hour (b, j).
- `goalqueue.json` has queued goals and `candidate` null for more than 30 minutes without a healthy slot holder (c, d):
  #762.
- A sentry-capped ticket that carries a CI or release label (g).

**First alert to add: "slots idle while work waits"** (queue non-empty, or a no-owner ticket exists, and running <
MAX_CONCURRENT for 10+ minutes). It needs a sink: today there is none (item 2). The status page is the only channel JP
already looks at; #762 is the place for the goal-side banner.

## 6. Fixed in this audit

- **Queue drain starts up to 3 queued runs per tick** (`supervisor.sh` step 2, `DRAIN_MAX_PER_TICK=3` and
  `DRAIN_MEM_PER_LAUNCH_MB=1200` in `config.sh`). Oldest `queued_at` first, as before. The first launch uses the tick's
  single capacity decision (#63, #714 unchanged); each extra launch re-checks `has_capacity` and needs
  `MEM_FLOOR_MB + 1200 MB x launches already made this tick` free, because free memory lags a run that has just started
  (VM OOM, 2026-11-01). A stop is logged as `[drain] stopping after N launch(es): <reason>`. A lost claim drops that entry
  and moves to the next; an unreadable claim keeps the entry and ends the drain for the tick. `DRAIN_MAX_PER_TICK=1`
  restores the old behaviour. Tests: `tests/test-supervisor-queue-z-multi-drain.sh` (5 cases); the ordering cases in
  `test-supervisor-queue-order.sh` pin the cap to 1. On tonight's Mac numbers this turns a 2.5 h drain of 15 tickets
  into about 5 ticks.
- **`gh-budget.sh` unmark bug**: the synced-repo removal no longer builds a sed expression from `owner/repo` (test:
  `tests/test-issue637-since-unmark-slash.sh`).

## 7. Left for JP, and why

- **Where alerts go.** Every pipeline alert is a no-op on both hosts (item 2). Choosing a Slack channel or webhook again is
  JP's call (he turned it off for noise). Recommendation: one low-volume channel that only gets the "slots idle while
  work waits" and "goal queue stalled" alerts, or rely on the status page banner (#762).
- **Auto-resume of held runs after a JP GO or a delivery-lead DECISION** (item 3, 10 tickets now). This would relaunch
  tickets outside any goal while `SHARED_DISPATCH_ENABLED=0` says only goal work auto-runs, and some of these runs are
  days old (spend). Proposed rule: extend the existing loop-cap resume (comment id newer than the gate, one resumed NOTE)
  to `[jp] GO`, `MOCKUPS APPROVED`, `SKIP MOCKUPS` and `[delivery-lead] DECISION` / `JP CONFIRMED`. Needs JP's yes.
- **The 47 "continue" tickets with no owner.** Either put them in a goal project (ticket intake, PR #765, covers new
  tickets only) or close them. A one-off triage is JP's call on scope.
- **Goal queue fail-closed and no preemption** (items 4, 6): design calls; #762 makes the stall visible.
- **Sentry cap for CI-critical tickets** (item 7): spend.
- **limit-shells killer and caps** (item 8): resource limits.
- **Mac `MAX_CLAUDE_PROCS=16`** below the formula (item 9): host config, JP's call (the Mac is his laptop).
- **The 4 claude-agents tickets with agent-go**: they will never run through the pipeline; an interactive session must
  pick them up or drop the label.
- **29 tickets on staging only, sales staging 316 commits ahead of main**: the release bot owns this; worth a look at why
  sales promotions lag.
