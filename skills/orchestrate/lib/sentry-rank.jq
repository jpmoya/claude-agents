# sentry-rank.jq — impact ranking of the sentry-auto-go candidates in supervisor.sh's shared dispatch
# (issue #761). Runs AFTER backlog-sort.jq has produced the final candidate order.
#
# Input (stdin): the cand_json array supervisor.sh already builds, one object per open agent-go candidate:
#   {n: <issue>, g: <goal-labelled>, s: <carries sentry-auto-go>, x: <also carries ci-critical>,
#    e: <Events: N>, u: <Users: M>, f: <First seen: YYYY-MM-DD>, ...}
# --argjson order: the candidate issue numbers in their current dispatch order (backlog-sort.jq's output), e.g. [4,9,7].
#
# Only sentry-auto-go slots (s, not g, not x) are reordered, and only among the positions they already occupy.
# Sort key, strictly in this order: users (most first), then events (most first), then older first-seen (ISO date,
# a missing date after dated ones), then the existing order. Every other slot — a non-Sentry ticket, a goal ticket,
# a ci-critical ticket (x, #781: its slot is never traded away, so error triage cannot outrank it or push it back), a
# number cand_json does not know — keeps its exact position. Missing or non-numeric e/u count 0.
#
# Interaction with the backlog priority store (backlog-sort.jq): this runs after it, so among the sentry-auto-go tickets
# the impact order overrides any manual backlog rank; the manual rank still decides every other (non-Sentry) slot and
# which positions the Sentry tickets occupy.
#
# Output: issue numbers, one per line, in final dispatch order (same shape as backlog-sort.jq).
def num: if type == "number" and . >= 0 then . else 0 end;
. as $c
| ($c | map({key: (.n | tostring), value: .}) | from_entries) as $by
| ($order | to_entries
    | map({i: .key, n: .value, o: ($by[(.value | tostring)] // {})})
    | map(. + {el: ((.o.s == true) and ((.o.g // false) | not) and ((.o.x // false) | not)),
               u: (.o.u | num), e: (.o.e | num),
               f: (if (.o.f | type) == "string" and (.o.f | length) > 0 then [0, .o.f] else [1, ""] end)})) as $seq
| ($seq | map(select(.el)) | sort_by([-.u, -.e, .f, .i]) | map(.n)) as $ranked
| (reduce $seq[] as $it
     ({out: [], q: $ranked};
      if $it.el then {out: (.out + [.q[0]]), q: .q[1:]}
      else {out: (.out + [$it.n]), q: .q} end)
  ).out
| .[]
