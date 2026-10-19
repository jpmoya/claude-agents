#!/usr/bin/env bash
# ci-report.sh: where is CI slow? Queue waits and run times per job (GitHub API) plus host pressure
# (the per-minute samples gha-metrics.sh writes on each runner host). Run it from the Mac.
# Usage: ci-report.sh [--days N] [--runs N]
# Env:   REPOS  repos to read   (default: Benjis-Plants/scheduler Benjis-Plants/benjis-sales-tool)
#        HOSTS  ssh targets     (default: none; e.g. "claude@178.156.187.130 root@178.156.204.167")
#        CI_REPORT_JOBS_FILE / CI_REPORT_HOST_DIR  test seams: read fixtures instead of GitHub / ssh
set -euo pipefail

DAYS=7 RUNS=150
while [ $# -gt 0 ]; do
  case $1 in
    --days) DAYS=${2:?--days needs a value}; shift 2 ;;
    --runs) RUNS=${2:?--runs needs a value}; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "ci-report.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ $DAYS =~ ^[0-9]+$ ]] && [[ $RUNS =~ ^[0-9]+$ ]] || { echo "ci-report.sh: --days/--runs must be integers" >&2; exit 2; }
REPOS=${REPOS:-"Benjis-Plants/scheduler Benjis-Plants/benjis-sales-tool"}
HOSTS=${HOSTS:-}

since=$(date -u -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null || date -u -d "-$DAYS days" +%Y-%m-%d)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ---- 1. one JSON line per job: repo, name, runner kind, queue seconds, run seconds ------------
jobs="$tmp/jobs.jsonl"
if [ -n "${CI_REPORT_JOBS_FILE:-}" ]; then cp "$CI_REPORT_JOBS_FILE" "$jobs"; else
  : > "$jobs"
  for repo in $REPOS; do
    ids=$(gh api "repos/$repo/actions/runs?created=>=$since&per_page=100" --paginate --jq '.workflow_runs[].id' | head -n "$RUNS") || true
    for id in $ids; do
      gh api "repos/$repo/actions/runs/$id/jobs?per_page=100" --paginate --jq '.jobs[]
        | select(.started_at != null and .completed_at != null and .conclusion != "skipped")
        | {repo: "'"$repo"'", name, runner: (.runner_name // ""), labels: (.labels | join(",")),
           conclusion, created: .created_at, started: .started_at, completed: .completed_at}' 2>/dev/null >> "$jobs" || true
    done
  done
fi

echo "CI REPORT  last $DAYS days (since $since), $(jq -s 'length' "$jobs") jobs"
echo

# ---- 2. per-job table, self-hosted vs GitHub-hosted ---------------------------------------------
jq -rs '
  def pct($p): sort | if length == 0 then 0 else .[([((length * $p) | floor), length - 1] | min)] end;
  def secs: (. | sub("\\.[0-9]+Z$"; "Z") | fromdate);
  map(. + {kind: (if (.labels | test("benjis-ci")) then "self-hosted" else "hosted" end),
           queue: ((.started | secs) - (.created | secs)),
           dur: ((.completed | secs) - (.started | secs))})
  | group_by(.kind)[]
  | . as $g | "== \($g[0].kind) ==",
    "job (repo)                                  runs  run p50  run p90  wait p50  wait p90  wait max",
    ( $g | group_by(.repo + " " + .name) | map({k: (.[0].name + " (" + (.[0].repo | split("/")[1]) + ")"), n: length,
        d: ([.[].dur] | pct(0.5)), d9: ([.[].dur] | pct(0.9)),
        q: ([.[].queue] | pct(0.5)), q9: ([.[].queue] | pct(0.9)), qm: ([.[].queue] | max)})
      | sort_by(-.q9)[] | "\(.k | .[0:42] | . + (" " * (42 - length))) \(.n | tostring | (" " * (5 - length)) + .)  \(.d / 60 | floor | tostring | (" " * (4 - length)) + .)m   \(.d9 / 60 | floor | tostring | (" " * (4 - length)) + .)m   \(.q / 60 | floor | tostring | (" " * (5 - length)) + .)m   \(.q9 / 60 | floor | tostring | (" " * (5 - length)) + .)m   \(.qm / 60 | floor | tostring | (" " * (5 - length)) + .)m" ),
    ""' "$jobs"

# ---- 3. host pressure ---------------------------------------------------------------------------
hostsum() { # csv on stdin -> summary line
  awk -F, 'NR>1 && $1!="" {
      n++; if (min==""||$2<min) min=$2; if ($4>l) l=$4; if ($5>st) st=$5; if ($6>d) d=$6; if ($7>gm) gm=$7
      if (first=="") first=$8; last=$8; if ($9>0 && $10>=$9) sat++; if ($10>0) busy++ }
    END { if (!n) { print "no samples"; exit }
      printf "samples=%d  min_free_mem=%dMB  peak_gha_mem=%dMB  peak_load=%.1f  peak_steal=%.1f%%  disk_max=%d%%  oom_kills=%d  all_slots_busy=%d%%  any_job=%d%%\n",
        n, min, gm, l, st, d, last-first, 100*sat/n, 100*busy/n }'
}
echo "== hosts =="
suggest=()
host_lines=()
if [ -n "${CI_REPORT_HOST_DIR:-}" ]; then
  for f in "$CI_REPORT_HOST_DIR"/*.csv; do [ -e "$f" ] && host_lines+=("$(basename "$f" .csv)|$(hostsum < "$f")"); done
else
  for h in $HOSTS; do
    host_lines+=("$h|$(ssh -o ConnectTimeout=15 "$h" "tail -n $((DAYS * 1440 + 1)) /var/log/gha/host.csv" 2>/dev/null | hostsum || echo unreachable)")
  done
fi
[ "${#host_lines[@]}" -gt 0 ] || echo "(no hosts given; set HOSTS to read the per-minute samples)"
for l in "${host_lines[@]:-}"; do
  [ -n "$l" ] || continue
  echo "${l%%|*}: ${l#*|}"
  v=${l#*|}
  num() { sed -n "s/.*$1=\([0-9.]*\).*/\1/p" <<<"$v"; }
  [ "$(num oom_kills)" = "" ] || [ "${l#*|}" = "no samples" ] || {
    [ "$(num oom_kills)" -gt 0 ] && suggest+=("${l%%|*}: $(num oom_kills) job(s) killed for memory -> fewer slots here or a bigger server")
    [ "$(num min_free_mem)" -lt 800 ] && suggest+=("${l%%|*}: free memory fell to $(num min_free_mem)MB -> memory-bound; do not add slots")
    awk -v s="$(num all_slots_busy)" 'BEGIN{exit !(s>=30)}' && suggest+=("${l%%|*}: every slot busy $(num all_slots_busy)% of the time -> add a slot or a second server")
    awk -v s="$(num peak_steal)" 'BEGIN{exit !(s>=10)}' && suggest+=("${l%%|*}: CPU steal $(num peak_steal)% -> shared cores are noisy; consider dedicated CPUs")
    [ "$(num disk_max)" -ge 85 ] && suggest+=("${l%%|*}: disk $(num disk_max)% -> prune or add a volume")
  }
done
# A slot service can show "active" while its runner is dead (wedged host: disk full, Docker hung). Compare the host's
# active slot services with the runners GitHub lists as online under the host's name; any mismatch is a down host.
if [ -z "${CI_REPORT_HOST_DIR:-}" ] && [ -n "$HOSTS" ]; then
  online_names=$(gh api --paginate "orgs/${ORG:-Benjis-Plants}/actions/runners" --jq '.runners[]|select(.status=="online")|.name' 2>/dev/null || true)
  for h in $HOSTS; do
    hn=$(ssh -o ConnectTimeout=15 "$h" 'hostname' 2>/dev/null || true)
    act=$(ssh -o ConnectTimeout=15 "$h" 'systemctl list-units "gha-slot@*" --no-legend --state=active 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ' || true)
    if [ -z "$hn" ] || [ -z "$act" ]; then suggest+=("$h: host unreachable over ssh -> treat as down"); continue; fi
    on=$(grep -ci -- "^gha-${hn}-" <<<"$online_names" || true)
    echo "$h: slot services active=$act, runners online on GitHub=$on"
    [ "$act" -gt "$on" ] && suggest+=("$h: $act slot service(s) active but only $on runner(s) online on GitHub -> host looks wedged (disk/Docker); free space and restart the slots")
  done
  echo
fi

echo

# ---- 4. plain-language summary ------------------------------------------------------------------
worst=$(jq -rs '
  def secs: (. | sub("\\.[0-9]+Z$"; "Z") | fromdate);
  map(select(.labels | test("benjis-ci")) | {name, q: ((.started | secs) - (.created | secs))})
  | if length == 0 then "" else (sort_by(-.q)[0] | "\(.name) waited \(.q / 60 | floor) min in line") end' "$jobs")
echo "== top bottlenecks =="
[ -z "$worst" ] || echo "- longest wait for a runner slot: $worst"
slow=$(jq -rs '
  def secs: (. | sub("\\.[0-9]+Z$"; "Z") | fromdate);
  map({name, d: ((.completed | secs) - (.started | secs))}) | group_by(.name)
  | map({name: .[0].name, total: (map(.d) | add), n: length}) | sort_by(-.total)[:3][]
  | "- most runner time: \(.name) (\(.n) runs, \(.total / 3600 * 10 | floor / 10) h total)"' "$jobs")
[ -z "$slow" ] || echo "$slow"
for s in "${suggest[@]:-}"; do [ -z "$s" ] || echo "- $s"; done
