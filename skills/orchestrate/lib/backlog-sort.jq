# backlog-sort.jq — goal-position-preserving reorder of supervisor.sh's shared-dispatch
# candidates by JP's stored backlog priority (issue: backlog reorder view, status page).
#
# Input (stdin): the JSON array supervisor.sh's dispatch `--jq` already builds, one object per
# open agent-go candidate, already sorted by today's tiebreak (`k` = [tier, major, minor, patch,
# issue]) — see supervisor.sh around "5. Shared dispatch":
#   {n: <issue number>, g: <true if the ticket carries a "goal: " label>, k: [...]}
# --argjson prio: the per-repo rank map from $PIPE/backlog-priority.json, e.g. {"12": 0, "5": 1}
# (lower rank = dispatched first); {} when the store is empty, missing or unreadable — the caller
# (supervisor.sh) is responsible for defaulting to {} on any read/parse failure, never aborting
# dispatch for a corrupt store.
#
# A goal-labelled ticket (g == true) is NEVER reordered: it keeps the exact array position it
# already held (its slot in $ordered). Only non-goal slots are refilled — in priority order first
# (lowest rank wins), then by today's tiebreak for any ticket the store has no rank for (so an
# untracked ticket defaults to the bottom of the explicitly-ranked ones, in today's order). This
# guarantees an empty store reproduces today's order exactly, and a ranked standalone ticket can
# never take a goal ticket's position in the list — it only ever swaps with another standalone
# ticket's position.
#
# Output: issue numbers, one per line, in final dispatch order (same shape the old inline
# `sort_by(.k) | .[].n` produced).
. as $ordered
| ($ordered
    | map(select(.g | not))
    | map(. + {r: ($prio[(.n|tostring)] // null)})
    | sort_by([(if .r == null then 1 else 0 end), (.r // 0), .k])
    | map(.n)) as $new_nongoal
| (reduce $ordered[] as $it
     ({out: [], q: $new_nongoal};
      if $it.g then {out: (.out + [$it.n]), q: .q}
      else {out: (.out + [.q[0]]), q: .q[1:]} end)
  ).out
| .[]
