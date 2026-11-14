# Issue #660 — infra/ci-runners/ci-queue-collect.sh: live duration + health metrics per category.
#
# A brand-new, slower-cadence (own throttle, own attempt/state files) sibling data pull decoupled
# from the existing queue-depth cadence (#643/#645/#648/#655/#658, all exercised in
# test-ciqueue-collector.sh). Gated behind CI_QUEUE_METRICS_ENABLED (default 0) so every
# pre-existing collector test (which never sets it) sees ZERO behavior change — this file is the
# only place that turns it on.
#
# Prefix ciqm_ / CIQM_. Real repo names (scripts/ci-metrics.repos is already public), same
# precedent as test-ciqueue-collector.sh.

HERE_CIQM=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT_CIQM=$(cd "$HERE_CIQM/../../.." && pwd)
COLLECTOR_CIQM="$REPO_ROOT_CIQM/infra/ci-runners/ci-queue-collect.sh"

# _ciqm_empty_queue_fixtures <dir> <repo...> — every repo in the collector's loop needs a
# queued/in_progress fixture pair regardless of whether this test cares about queue data; without
# this _ciq_collect_repo's shaped-call would fail and abort the whole cycle before metrics ever run.
_ciqm_empty_queue_fixtures() {
  local dir=$1; shift
  local repo safe
  for repo in "$@"; do
    safe=${repo//\//__}
    echo '{"workflow_runs":[]}' > "$dir/runs-${safe}-queued.json"
    echo '{"workflow_runs":[]}' > "$dir/runs-${safe}-in_progress.json"
  done
}

_ciqm_empty_runners() {  # <dir> — zero runners online, enough busy/total for non-"down" tests to override
  local dir=$1
  cat > "$dir/runners-org.json" <<'EOF'
{"total_count":0,"runners":[]}
EOF
  cat > "$dir/runners-repo.json" <<'EOF'
{"total_count":0,"runners":[]}
EOF
}

# _ciqm_online_runners <dir> <online> <busy> — org-level runners only (repo-level stays empty), for
# tests that need runners_total > 0 so "down" (zero online runners) never fires.
_ciqm_online_runners() {
  local dir=$1 online=$2 busy=$3 i runs='[' b
  for i in $(seq 1 "$online"); do
    if [ "$i" -le "$busy" ]; then b=true; else b=false; fi
    runs="$runs{\"id\":$i,\"name\":\"r$i\",\"status\":\"online\",\"busy\":$b},"
  done
  runs="${runs%,}]"
  echo "{\"total_count\":$online,\"runners\":$runs}" > "$dir/runners-org.json"
  echo '{"total_count":0,"runners":[]}' > "$dir/runners-repo.json"
}

# _ciqm_repos_file <path> <repo...> — a minimal ci-metrics.repos-shaped fixture (own file, never
# the real scripts/ci-metrics.repos, so each test controls exactly which repos are "tracked").
_ciqm_repos_file() {
  local path=$1; shift
  local repo
  : > "$path"
  for repo in "$@"; do printf '%s\n' "$repo" >> "$path"; done
}

# _ciqm_run <pipe> <fixdir> <reposfile> [extra env...] — one forced-queue-cycle, metrics explicitly
# force-run this cycle regardless of its own throttle (CI_QUEUE_METRICS_FORCE=1), isolated from the
# real host's pipeline state and from every other test's fixtures.
_ciqm_run() {
  local pipe=$1 fixdir=$2 reposfile=$3; shift 3
  ( CI_QUEUE_FORCE=1 \
    CI_QUEUE_METRICS_ENABLED=1 CI_QUEUE_METRICS_FORCE=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" \
    CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" \
    CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_METRICS_OUT="$pipe/ci-metrics.json" \
    CI_QUEUE_METRICS_ATTEMPT_FILE="$pipe/metrics-attempt" \
    CI_QUEUE_METRICS_STATE_FILE="$pipe/metrics-state.json" \
    CI_QUEUE_REPOS_FILE="$reposfile" \
    CI_QUEUE_FIXTURE_DIR="$fixdir" \
    env "$@" bash "$COLLECTOR_CIQM" )
}

_ciqm_calls() { cat "$1/calls.log" 2>/dev/null; }

# One completed-run fixture entry. <repo> here is the API PATH queried (may be an alias); the run
# object's OWN .repository.full_name is what the implementation must key categorization on.
_ciqm_run_obj() {  # <id> <repo_full_name> <name> <event> <head_branch> <conclusion|null> <started> <updated>
  local id=$1 repo=$2 name=$3 event=$4 branch=$5 concl=$6 started=$7 updated=$8
  local concl_json='null'
  [ "$concl" = "null" ] || concl_json="\"$concl\""
  printf '{"id":%s,"repository":{"full_name":"%s"},"name":"%s","event":"%s","head_branch":"%s","conclusion":%s,"run_started_at":"%s","updated_at":"%s"}' \
    "$id" "$repo" "$name" "$event" "$branch" "$concl_json" "$started" "$updated"
}

_ciqm_write_completed() {  # <dir> <api-repo> <run_obj_json...>
  local dir=$1 repo=$2; shift 2
  local safe=${repo//\//__} body='['
  local r
  for r in "$@"; do body="$body$r,"; done
  body="${body%,}]"
  printf '{"workflow_runs":%s}\n' "$body" > "$dir/runs-${safe}-completed.json"
}

# ---- AC: avg/p50/p90 per category, hand-computed ----------------------------------------------
# sales-tool PR CI: durations 100,300 (both "today", one success one failure) -> n=2 avg=200
#   sorted [100,300]; p50 idx=ceil(50*2/100)-1=0 -> 100; p90 idx=ceil(90*2/100)-1=1 -> 300.
#   pass_rate: 1 success / 2 eligible = 50.
# ops-tool prod_deploy (push, head_branch main, name "Deploy to production"): duration 500, n=1.
# ops-tool staging_deploy (push, head_branch staging, name "Deploy to staging"): duration 50, n=1.
# ops-tool PR CI (pull_request): duration 20, n=1.
test_ciqm_ac_duration_and_pass_rate_per_category() {
  local pipe fixdir reposfile out
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool" "Benjis-Plants/benjis-ops-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool" "Benjis-Plants/benjis-ops-tool"
  _ciqm_online_runners "$fixdir" 2 1

  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "Secret scan" pull_request feature-a success "2026-11-10T10:00:00Z" "2026-11-10T10:01:40Z")" \
    "$(_ciqm_run_obj 2 Benjis-Plants/benjis-sales-tool "Secret scan" pull_request feature-b failure "2026-11-10T11:00:00Z" "2026-11-10T11:05:00Z")"
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-ops-tool" \
    "$(_ciqm_run_obj 3 Benjis-Plants/benjis-ops-tool "Deploy to production" push main success "2026-11-10T09:00:00Z" "2026-11-10T09:08:20Z")" \
    "$(_ciqm_run_obj 4 Benjis-Plants/benjis-ops-tool "Deploy to staging" push staging success "2026-11-10T09:00:00Z" "2026-11-10T09:00:50Z")" \
    "$(_ciqm_run_obj 5 Benjis-Plants/benjis-ops-tool "Secret scan" pull_request feature-c success "2026-11-10T09:00:00Z" "2026-11-10T09:00:20Z")"

  out=$(_ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400) # 2026-11-10T11:00:00Z-ish day
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  local sales ops_pr prod stag
  sales=$(printf '%s' "$out" | jq -c '.ci_metrics.categories[] | select(.key=="sales_tool_pr")')
  ops_pr=$(printf '%s' "$out" | jq -c '.ci_metrics.categories[] | select(.key=="ops_tool_pr")')
  prod=$(printf '%s' "$out" | jq -c '.ci_metrics.categories[] | select(.key=="prod_deploy")')
  stag=$(printf '%s' "$out" | jq -c '.ci_metrics.categories[] | select(.key=="staging_deploy")')

  assert_eq "$sales" '{"key":"sales_tool_pr","n":2,"avg_secs":200,"p50_secs":100,"p90_secs":300,"pass_rate_pct":50}' "AC: sales-tool PR CI duration+pass_rate" || return 1
  assert_eq "$ops_pr" '{"key":"ops_tool_pr","n":1,"avg_secs":20,"p50_secs":20,"p90_secs":20,"pass_rate_pct":100}' "AC: ops-tool PR CI" || return 1
  assert_eq "$prod" '{"key":"prod_deploy","n":1,"avg_secs":500,"p50_secs":500,"p90_secs":500,"pass_rate_pct":100}' "AC: prod_deploy (head_branch main)" || return 1
  assert_eq "$stag" '{"key":"staging_deploy","n":1,"avg_secs":50,"p50_secs":50,"p90_secs":50,"pass_rate_pct":100}' "AC: staging_deploy (head_branch staging)" || return 1
}

# ---- AC: conclusion:null excluded from pass/fail rate, not counted as a failure ---------------
# Reworked per PR #713 review (MEDIUM): a null-conclusion run is now ALSO excluded from n/duration
# (same eligibility filter as pass_rate, and as cancelled/skipped below) -- it never really ran to
# a verdict, so it shouldn't drag the category's avg/p50/p90 either.
test_ciqm_ac_null_conclusion_excluded_from_pass_rate_not_a_failure() {
  local pipe fixdir reposfile out cat
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 0

  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")" \
    "$(_ciqm_run_obj 2 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-b null "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  cat=$(printf '%s' "$out" | jq -c '.ci_metrics.categories[] | select(.key=="sales_tool_pr")')
  assert_eq "$(printf '%s' "$cat" | jq '.n')" "1" "null-conclusion run is excluded from n/duration too (only the 1 success counts)" || return 1
  assert_eq "$(printf '%s' "$cat" | jq '.pass_rate_pct')" "100" "null-conclusion run excluded from the pass_rate denominator (1/1, not 1/2)" || return 1
}

# ---- AC: zero completed runs in a category -> omitted, not zero/error -------------------------
test_ciqm_ac_zero_runs_in_category_is_omitted() {
  local pipe fixdir reposfile out n
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool" "Benjis-Plants/benjis-ops-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool" "Benjis-Plants/benjis-ops-tool"
  _ciqm_online_runners "$fixdir" 1 0

  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool"   # none
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-ops-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-ops-tool "Secret scan" pull_request feature-a success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  n=$(printf '%s' "$out" | jq '.ci_metrics.categories | length')
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$n" "1" "a category with zero completed runs is omitted entirely (only ops_tool_pr present)" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.ci_metrics.categories[0].key')" "ops_tool_pr" "the one present category is ops_tool_pr" || return 1
}

# ---- AC: dedup by run id (scheduler/ops-tool alias — same physical repo) -----------------------
test_ciqm_ac_dedup_by_id_across_the_scheduler_ops_tool_alias() {
  local pipe fixdir reposfile out n
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/scheduler" "Benjis-Plants/benjis-ops-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/scheduler" "Benjis-Plants/benjis-ops-tool"
  _ciqm_online_runners "$fixdir" 1 0

  # Same run id (999), same canonical repository.full_name (ops-tool), returned verbatim by BOTH
  # the scheduler-alias API path and the ops-tool API path — exactly what GitHub really does
  # (verified live: both paths resolve to the same repo id and the same run objects).
  local run obj
  obj=$(_ciqm_run_obj 999 Benjis-Plants/benjis-ops-tool "Secret scan" pull_request feature-a success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")
  _ciqm_write_completed "$fixdir" "Benjis-Plants/scheduler" "$obj"
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-ops-tool" "$obj"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  n=$(printf '%s' "$out" | jq '.ci_metrics.categories[] | select(.key=="ops_tool_pr") | .n')
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$n" "1" "the same run id fetched via both the scheduler alias and ops-tool is counted exactly once" || return 1
}

# ---- AC: exactly 1 status=completed call per tracked repo per metrics cycle -------------------
# test-reviewer finding (PR #713, Tier 2 coverage gap): proving this with EMPTY completed-run
# fixtures can't catch a regression that adds a per-run lookup (e.g. a `/jobs` call per completed
# run, mirroring the queue path's own per-job lookups) — with zero runs in the response, such a
# lookup loop would never execute even if it existed. Each repo below gets multiple completed runs
# (several categories, several ids) so a broken "no per-job lookups" guarantee would actually fire
# extra calls and this assertion would catch it.
test_ciqm_ac_exactly_one_completed_call_per_repo() {
  local pipe fixdir reposfile calls_off calls_on
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool" "Benjis-Plants/benjis-ops-tool" "jpmoya/claude-agents"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool" "Benjis-Plants/benjis-ops-tool" "jpmoya/claude-agents"
  _ciqm_online_runners "$fixdir" 1 0
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")" \
    "$(_ciqm_run_obj 2 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-b failure "2026-11-10T09:00:00Z" "2026-11-10T09:02:00Z")"
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-ops-tool" \
    "$(_ciqm_run_obj 3 Benjis-Plants/benjis-ops-tool "Deploy to production" push main success "2026-11-10T09:00:00Z" "2026-11-10T09:08:00Z")" \
    "$(_ciqm_run_obj 4 Benjis-Plants/benjis-ops-tool "Deploy to staging" push staging success "2026-11-10T09:00:00Z" "2026-11-10T09:00:50Z")" \
    "$(_ciqm_run_obj 5 Benjis-Plants/benjis-ops-tool "CI" pull_request feature-c success "2026-11-10T09:00:00Z" "2026-11-10T09:00:20Z")"
  _ciqm_write_completed "$fixdir" "jpmoya/claude-agents" \
    "$(_ciqm_run_obj 6 jpmoya/claude-agents "CI" pull_request feature-d success "2026-11-10T09:00:00Z" "2026-11-10T09:00:30Z")"

  # Baseline: metrics disabled (default) -> queue-only call count.
  ( CI_QUEUE_FORCE=1 CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_CALL_LOG="$pipe/calls.log" CI_QUEUE_REPOS_FILE="$reposfile" CI_QUEUE_FIXTURE_DIR="$fixdir" \
    bash "$COLLECTOR_CIQM" )
  calls_off=$(_ciqm_calls "$pipe")

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  calls_on=$(_ciqm_calls "$pipe")
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$((calls_on - calls_off))" "3" "AC: metrics adds exactly 1 completed-run call per tracked repo, even with multiple completed runs per repo (3 repos -> +3, no per-run lookups)" || return 1
}

# ---- AC: all runners offline -> ci_health down -------------------------------------------------
test_ciqm_ac_all_runners_offline_is_down() {
  local pipe fixdir reposfile out
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_runners "$fixdir"
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$(printf '%s' "$out" | jq -r '.ci_health')" "down" "zero online runners -> ci_health down" || return 1
}

# ---- AC: queued job older than threshold with 0 busy runners -> degraded ----------------------
test_ciqm_ac_old_queued_job_with_zero_busy_is_degraded() {
  local pipe fixdir reposfile out
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 0   # 1 online, 0 busy -> not "down"
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool"

  cat > "$fixdir/runs-Benjis-Plants__benjis-sales-tool-queued.json" <<'EOF'
{"workflow_runs":[{"id":101,"name":"CI","event":"pull_request","actor":{"login":"jp"}}]}
EOF
  echo '{"workflow_runs":[]}' > "$fixdir/runs-Benjis-Plants__benjis-sales-tool-in_progress.json"
  # queued 20 minutes before "now" (CI_QUEUE_NOW below) -> older than the 15-min default threshold.
  cat > "$fixdir/jobs-101.json" <<'EOF'
{"jobs":[{"id":1,"status":"queued","created_at":"2026-11-10T08:40:00Z"}]}
EOF

  out=$(_ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794301200)   # 2026-11-10T09:00:00Z
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$(printf '%s' "$out" | jq -r '.ci_health')" "degraded" "queued job older than 15 min, 0 runners busy -> degraded" || return 1
}

# ---- AC: ci_health "ok" when none of the degraded/down conditions hold -------------------------
test_ciqm_ac_ok_when_nothing_is_wrong() {
  local pipe fixdir reposfile out
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$(printf '%s' "$out" | jq -r '.ci_health')" "ok" "nothing wrong -> ok" || return 1
}

# ---- AC: malformed status=completed response -> previous ci_metrics/ci_health kept untouched --
test_ciqm_ac_malformed_completed_response_keeps_previous_snapshot() {
  local pipe fixdir reposfile before_metrics before_health after_metrics after_health out out1
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  before_metrics=$(cat "$pipe/ci-metrics.json" 2>/dev/null)
  out1=$(cat "$pipe/status-ci.json" 2>/dev/null)
  before_health=$(printf '%s' "$out1" | jq -r '.ci_health')

  # Next cycle: malformed (missing "workflow_runs") completed response.
  echo '{}' > "$fixdir/runs-Benjis-Plants__benjis-sales-tool-completed.json"
  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308700 >/dev/null
  after_metrics=$(cat "$pipe/ci-metrics.json" 2>/dev/null)
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  after_health=$(printf '%s' "$out" | jq -r '.ci_health')
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$before_metrics" "$after_metrics" "a malformed completed-runs response leaves the previous ci_metrics snapshot byte-identical" || return 1
  assert_ne "$out" "" "the rest of the cycle (ci_queue itself) still succeeds and writes \$OUT" || return 1
  assert_eq "$(printf '%s' "$out" | jq -c '.ci_metrics')" "$(printf '%s' "$after_metrics" | jq -c .)" "the carried-forward ci_metrics still rides along in \$OUT" || return 1
  # test-reviewer finding (PR #713, Tier 2 coverage gap): the AC also covers ci_health being left
  # untouched by a malformed completed-runs response, not just ci_metrics — both snapshots here are
  # computed fresh each cycle from the same still-good runner/queue signals, so ci_health staying
  # "ok" across the malformed cycle is the honest expectation (not a frozen carry-forward like
  # ci_metrics, since ci_health has no API dependency of its own on this path).
  # jq -r on a missing key prints the literal string "null", not empty -- assert the real expected
  # value directly rather than a non-empty guard that a "null" string would also satisfy.
  assert_eq "$before_health" "ok" "sanity: the first cycle really did compute a real ci_health value (online+busy runner, nothing wrong)" || return 1
  assert_eq "$before_health" "$after_health" "ci_health is unaffected by a malformed completed-runs response (still computed from the unaffected runner/queue signals)" || return 1
}

# ---- AC: metrics disabled by default -- zero behavior change for an un-opted-in invocation ----
test_ciqm_disabled_by_default_adds_zero_calls_and_no_key() {
  local pipe fixdir reposfile out
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1
  # Deliberately no completed-runs fixture at all -- if metrics ran despite being disabled, the
  # shaped call would fail loudly; a missing fixture file makes the gate itself the only thing
  # that can make this test pass.
  # Pre-seed a VALID prior ci-metrics.json at the explicit path a disabled run would otherwise
  # default to reading from -- proves "disabled never even reads $METRICS_OUT", not just "never
  # writes it": a host that flips the feature off (or a stale leftover file) must never surface a
  # frozen snapshot instead of simply omitting the key.
  echo '{"as_of":"2020-01-01T00:00:00Z","categories":[]}' > "$pipe/ci-metrics.json"

  ( CI_QUEUE_FORCE=1 CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_CALL_LOG="$pipe/calls.log" CI_QUEUE_REPOS_FILE="$reposfile" CI_QUEUE_FIXTURE_DIR="$fixdir" \
    CI_QUEUE_METRICS_OUT="$pipe/ci-metrics.json" \
    bash "$COLLECTOR_CIQM" )
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  local has_metrics metrics_file_after
  has_metrics=$(printf '%s' "$out" | jq 'has("ci_metrics")')
  metrics_file_after=$(cat "$pipe/ci-metrics.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$has_metrics" "false" "CI_QUEUE_METRICS_ENABLED unset (default off) -> no ci_metrics key at all, even with a stale file sitting at \$METRICS_OUT" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.ci_health')" "ok" "ci_health is still computed from runner/queue signals alone when metrics is off" || return 1
  assert_eq "$metrics_file_after" '{"as_of":"2020-01-01T00:00:00Z","categories":[]}' "disabled metrics never touches (reads OR writes) its own side-state file" || return 1
}

# ---- AC: metrics' own throttle (decoupled from the queue cadence's CI_QUEUE_FORCE) -------------
test_ciqm_own_throttle_skips_a_not_yet_due_cycle() {
  local pipe fixdir reposfile calls1 calls2 metrics1 metrics2
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")"

  # First cycle: metrics enabled, due by default (first-ever, no prior attempt/out file), NOT
  # force (CI_QUEUE_METRICS_FORCE unset) -- proves "due" alone is enough on a cold start.
  ( CI_QUEUE_FORCE=1 CI_QUEUE_METRICS_ENABLED=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_METRICS_OUT="$pipe/ci-metrics.json" CI_QUEUE_METRICS_ATTEMPT_FILE="$pipe/metrics-attempt" CI_QUEUE_METRICS_STATE_FILE="$pipe/metrics-state.json" \
    CI_QUEUE_REPOS_FILE="$reposfile" CI_QUEUE_FIXTURE_DIR="$fixdir" \
    bash "$COLLECTOR_CIQM" )
  calls1=$(_ciqm_calls "$pipe")
  metrics1=$(cat "$pipe/ci-metrics.json" 2>/dev/null)

  # Second cycle, immediately after: real wall-clock elapsed is a fraction of a second, nowhere
  # near CI_QUEUE_METRICS_INTERVAL_SECS (default 900s) -- must skip the completed-run fetch.
  echo '{}' > "$fixdir/runs-Benjis-Plants__benjis-sales-tool-completed.json"   # would fail if fetched
  ( CI_QUEUE_FORCE=1 CI_QUEUE_METRICS_ENABLED=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_METRICS_OUT="$pipe/ci-metrics.json" CI_QUEUE_METRICS_ATTEMPT_FILE="$pipe/metrics-attempt" CI_QUEUE_METRICS_STATE_FILE="$pipe/metrics-state.json" \
    CI_QUEUE_REPOS_FILE="$reposfile" CI_QUEUE_FIXTURE_DIR="$fixdir" \
    bash "$COLLECTOR_CIQM" )
  calls2=$(_ciqm_calls "$pipe")
  metrics2=$(cat "$pipe/ci-metrics.json" 2>/dev/null)

  # Baseline: same fixtures, metrics entirely disabled -> pure queue-cycle call count. Comparing
  # cycle 2 against cycle 1 directly would be wrong (cycle 1 legitimately cost one MORE call, the
  # completed-run fetch it was due for) — the baseline isolates "did cycle 2 make that extra call".
  local baseline_pipe baseline
  baseline_pipe=$(mktemp -d)
  ( CI_QUEUE_FORCE=1 CI_QUEUE_OUT="$baseline_pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$baseline_pipe/attempt" \
    CI_QUEUE_STATE_FILE="$baseline_pipe/state.json" CI_QUEUE_LOCKDIR="$baseline_pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$baseline_pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_CALL_LOG="$baseline_pipe/calls.log" CI_QUEUE_REPOS_FILE="$reposfile" CI_QUEUE_FIXTURE_DIR="$fixdir" \
    bash "$COLLECTOR_CIQM" )
  baseline=$(_ciqm_calls "$baseline_pipe")
  rm -rf "$pipe" "$fixdir" "$baseline_pipe"; rm -f "$reposfile"

  assert_eq "$calls2" "$baseline" "a metrics cycle well inside its own interval makes zero completed-run calls (matches the metrics-disabled baseline)" || return 1
  assert_ne "$calls1" "$baseline" "sanity: cycle 1 (due) really did cost one more call than the baseline" || return 1
  assert_eq "$metrics1" "$metrics2" "ci_metrics is carried forward unchanged when the metrics cycle is throttled" || return 1
}

# ---- AC: a pathologically long run is clamped, never drops the whole category ------------------
test_ciqm_ac_long_duration_clamped_keeps_category_present() {
  local pipe fixdir reposfile out cat
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1
  # 2 days (172800s) -- a manual environment-approval gate left open -- well past the 86400s cap.
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a success "2026-11-08T09:00:00Z" "2026-11-10T09:00:00Z")"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  cat=$(printf '%s' "$out" | jq -c '.ci_metrics.categories[] | select(.key=="sales_tool_pr")')
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$cat" '{"key":"sales_tool_pr","n":1,"avg_secs":86400,"p50_secs":86400,"p90_secs":86400,"pass_rate_pct":100}' \
    "a 2-day run is clamped to the 86400s cap, not dropped (and the category stays present)" || return 1
}

# ---- AC: cancelled/skipped are excluded from pass/fail rate, never counted as failures ----------
# Reworked per PR #713 review (MEDIUM — duration must use the SAME run-status filter as pass
# rate): cancelled/skipped runs finish in seconds (a supersede or a path-filter skip, not real CI
# work) and are now excluded from duration/n too, not just from the pass_rate denominator.
test_ciqm_ac_cancelled_and_skipped_excluded_not_counted_as_failures() {
  local pipe fixdir reposfile out cat
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")" \
    "$(_ciqm_run_obj 2 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-b cancelled "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")" \
    "$(_ciqm_run_obj 3 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-c skipped "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  cat=$(printf '%s' "$out" | jq -c '.ci_metrics.categories[] | select(.key=="sales_tool_pr")')
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$(printf '%s' "$cat" | jq '.n')" "1" "cancelled/skipped runs are excluded from n/duration too, consistent with the pass_rate filter (only the 1 success counts)" || return 1
  assert_eq "$(printf '%s' "$cat" | jq '.pass_rate_pct')" "100" "cancelled/skipped excluded from the pass_rate denominator (1/1, not 1/3)" || return 1
}

# ---- AC (PR #713 review follow-up): a category whose runs are ALL cancelled/skipped is omitted
# entirely (zero duration-eligible runs), same "zero eligible runs -> omitted" shape as zero
# completed runs -- never a jq division-by-zero crash, never a zeroed/null-average entry.
test_ciqm_ac_category_with_only_cancelled_skipped_is_omitted() {
  local pipe fixdir reposfile out n key
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool" "Benjis-Plants/benjis-ops-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool" "Benjis-Plants/benjis-ops-tool"
  _ciqm_online_runners "$fixdir" 1 1
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a cancelled "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")" \
    "$(_ciqm_run_obj 2 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-b skipped "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")"
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-ops-tool" \
    "$(_ciqm_run_obj 3 Benjis-Plants/benjis-ops-tool "CI" pull_request feature-c success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  n=$(printf '%s' "$out" | jq '.ci_metrics.categories | length')
  key=$(printf '%s' "$out" | jq -r '.ci_metrics.categories[0].key')
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$n" "1" "a category whose runs are all cancelled/skipped is omitted entirely (only ops_tool_pr survives)" || return 1
  assert_eq "$key" "ops_tool_pr" "the one present category is ops_tool_pr" || return 1
}

# ---- AC (PR #713 review follow-up): a cancelled/skipped run never drags the surviving avg down --
test_ciqm_ac_cancelled_run_excluded_from_average_duration() {
  local pipe fixdir reposfile out cat
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1
  # A real 600s success plus a 5s cancelled run (a concurrency-group supersede) -- the cancelled
  # run must never drag the category's avg/p50/p90 toward 5s.
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a success "2026-11-10T09:00:00Z" "2026-11-10T09:10:00Z")" \
    "$(_ciqm_run_obj 2 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-b cancelled "2026-11-10T09:00:00Z" "2026-11-10T09:00:05Z")"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  cat=$(printf '%s' "$out" | jq -c '.ci_metrics.categories[] | select(.key=="sales_tool_pr")')
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$cat" '{"key":"sales_tool_pr","n":1,"avg_secs":600,"p50_secs":600,"p90_secs":600,"pass_rate_pct":100}' \
    "the cancelled 5s run is excluded, leaving avg/p50/p90 at the real 600s success (n=1)" || return 1
}

# ---- AC (PR #713 review follow-up): duration is a ROLLING window, never restricted to today -----
test_ciqm_ac_prior_day_success_still_counts_toward_duration() {
  local pipe fixdir reposfile out cat
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1
  # A run that completed the day BEFORE "now" -- not today-eligible for pass_rate, but must still
  # count toward n/avg/p50/p90 (duration is a rolling window over every fetched completed run).
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a success "2026-11-09T09:00:00Z" "2026-11-09T09:01:40Z")"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null   # "now" is 2026-11-10
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  cat=$(printf '%s' "$out" | jq -c '.ci_metrics.categories[] | select(.key=="sales_tool_pr")')
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$cat" '{"key":"sales_tool_pr","n":1,"avg_secs":100,"p50_secs":100,"p90_secs":100,"pass_rate_pct":null}' \
    "a prior-day success still counts toward n/avg/p50/p90 (rolling window), even though it's excluded from pass_rate_pct (not today)" || return 1
}

# ---- Observability: Sentry capture on a malformed completed-runs response ----------------------
_ciqm_write_recording_curl() {  # <bindir>
  cat > "$1/curl" <<'EOF'
#!/bin/bash
echo "CALL $*" >> "$(dirname "$0")/calls"
exit 0
EOF
  chmod +x "$1/curl"
}

test_ciqm_obs_sentry_capture_on_malformed_completed_response() {
  local pipe fixdir reposfile bindir body
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp); bindir=$(mktemp -d)
  _ciqm_write_recording_curl "$bindir"
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1
  echo '{}' > "$fixdir/runs-Benjis-Plants__benjis-sales-tool-completed.json"   # malformed (no "workflow_runs")

  ( CI_QUEUE_FORCE=1 CI_QUEUE_METRICS_ENABLED=1 CI_QUEUE_METRICS_FORCE=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_METRICS_OUT="$pipe/ci-metrics.json" CI_QUEUE_METRICS_ATTEMPT_FILE="$pipe/metrics-attempt" CI_QUEUE_METRICS_STATE_FILE="$pipe/metrics-state.json" \
    CI_QUEUE_REPOS_FILE="$reposfile" CI_QUEUE_FIXTURE_DIR="$fixdir" \
    SENTRY_DSN="https://testkey@sentry.test/42" \
    PATH="$bindir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    bash "$COLLECTOR_CIQM" )
  body=$(grep "sentry.test" "$bindir/calls" 2>/dev/null)
  rm -rf "$pipe" "$fixdir" "$bindir"; rm -f "$reposfile"

  assert_contains "$body" "route\":\"ci-queue/collect\"" "Observability: metrics failure still reports route=ci-queue/collect to Sentry" || return 1
  assert_contains "$body" "metrics cycle failed" "Observability: the Sentry message identifies a METRICS cycle failure specifically" || return 1
}

# ---- AC: a matched run missing run_started_at/updated_at aborts, keeps the previous snapshot ---
test_ciqm_ac_missing_timestamp_aborts_keeps_previous_snapshot() {
  local pipe fixdir reposfile before after
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")"
  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  before=$(cat "$pipe/ci-metrics.json" 2>/dev/null)

  # Next cycle: a matched (pull_request, tracked repo) run with run_started_at missing entirely.
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    '{"id":2,"repository":{"full_name":"Benjis-Plants/benjis-sales-tool"},"name":"CI","event":"pull_request","head_branch":"feature-b","conclusion":"success","run_started_at":null,"updated_at":"2026-11-10T09:01:00Z"}'
  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308700 >/dev/null
  after=$(cat "$pipe/ci-metrics.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  # test-reviewer finding (PR #713, Tier 1 vacuous): without this guard, a reverted/missing
  # collector never writes ci-metrics.json at all, so before="" and after="" satisfy the equality
  # below with nothing actually aborted/preserved — this pins that the first cycle really did
  # write a real snapshot before the second cycle's abort is checked against it.
  assert_ne "$before" "" "sanity: the first cycle really did write a real ci_metrics snapshot" || return 1
  assert_eq "$before" "$after" "a matched run missing run_started_at aborts the metrics cycle cleanly, previous snapshot byte-identical" || return 1
}

# ---- Observability: Slack fires only on the 3rd consecutive METRICS failure (independent streak) -
test_ciqm_obs_slack_only_on_third_consecutive_metrics_failure() {
  local pipe fixdir reposfile bindir slack_calls
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp); bindir=$(mktemp -d)
  _ciqm_write_recording_curl "$bindir"
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1
  echo '{}' > "$fixdir/runs-Benjis-Plants__benjis-sales-tool-completed.json"   # malformed every cycle

  _ciqm_fail_cycle() {
    ( CI_QUEUE_FORCE=1 CI_QUEUE_METRICS_ENABLED=1 CI_QUEUE_METRICS_FORCE=1 \
      CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" CI_QUEUE_STATE_FILE="$pipe/state.json" \
      CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" CI_QUEUE_CALL_LOG="$pipe/calls.log" \
      CI_QUEUE_METRICS_OUT="$pipe/ci-metrics.json" CI_QUEUE_METRICS_ATTEMPT_FILE="$pipe/metrics-attempt" CI_QUEUE_METRICS_STATE_FILE="$pipe/metrics-state.json" \
      CI_QUEUE_REPOS_FILE="$reposfile" CI_QUEUE_FIXTURE_DIR="$fixdir" \
      SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X" \
      PATH="$bindir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
      bash "$COLLECTOR_CIQM" )
  }

  _ciqm_fail_cycle; _ciqm_fail_cycle   # queue side succeeds every time (fixtures are otherwise valid) -- only metrics fails
  slack_calls=$(grep -c "hooks.slack.test" "$bindir/calls" 2>/dev/null)
  assert_eq "${slack_calls:-0}" "0" "2 consecutive METRICS failures post no Slack message" || { rm -rf "$pipe" "$fixdir" "$bindir"; rm -f "$reposfile"; return 1; }

  _ciqm_fail_cycle   # 3rd consecutive metrics failure
  slack_calls=$(grep -c "hooks.slack.test" "$bindir/calls" 2>/dev/null)
  rm -rf "$pipe" "$fixdir" "$bindir"; rm -f "$reposfile"
  assert_eq "${slack_calls:-0}" "1" "the 3rd consecutive METRICS failure posts exactly one Slack message (its own independent streak)" || return 1
}

# ---- AC: today's pass rate below the threshold, with busy runners (not a stuck queue) -> degraded
test_ciqm_ac_low_pass_rate_is_degraded() {
  local pipe fixdir reposfile out
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1   # busy runner -- proves this isn't the stuck-queue leg
  # 1 success + 4 failures today = 5 samples (>= CI_QUEUE_DEGRADED_MIN_SAMPLES) at 20%.
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" \
    "$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")" \
    "$(_ciqm_run_obj 2 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-b failure "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")" \
    "$(_ciqm_run_obj 3 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-c failure "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")" \
    "$(_ciqm_run_obj 4 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-d failure "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")" \
    "$(_ciqm_run_obj 5 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-e failure "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$(printf '%s' "$out" | jq '.ci_metrics.pass_rate_pct')" "20" "sanity: 1/5 success is really 20% (the top-level OVERALL rate)" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.ci_metrics.pass_rate_n')" "5" "sanity: 5 eligible samples, meets CI_QUEUE_DEGRADED_MIN_SAMPLES" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.ci_health')" "degraded" "today's overall pass rate (20%) below the 80% default threshold -> degraded" || return 1
}

# ---- AC: the overall rate is NOT a count-weighted average of stale per-category rates ----------
# sales_tool_pr: 1 failure TODAY + 9 successes from a PRIOR day (same fetched page) -> n=10, but
# today-eligible = {the 1 failure} only, so that category's OWN pass_rate_pct is 0%.
# ops_tool_pr: 9 successes today -> category rate 100%, n=9.
# A naive "weighted average of the two categories' OWN rates by their n" would compute
# (0*10 + 100*9) / 19 = 47% -> wrongly degraded. The correct OVERALL rate only counts TODAY's
# eligible runs across both categories: (0 success + 9 success) / (1 + 9) = 90% -> ok.
test_ciqm_ac_overall_rate_not_weighted_by_stale_category_n() {
  local pipe fixdir reposfile out
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool" "Benjis-Plants/benjis-ops-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool" "Benjis-Plants/benjis-ops-tool"
  _ciqm_online_runners "$fixdir" 1 1

  local sales_runs=()
  sales_runs+=("$(_ciqm_run_obj 1 Benjis-Plants/benjis-sales-tool "CI" pull_request feature-a failure "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")")
  local i
  for i in 2 3 4 5 6 7 8 9 10; do
    sales_runs+=("$(_ciqm_run_obj "$i" Benjis-Plants/benjis-sales-tool "CI" pull_request "feature-$i" success "2026-11-09T09:00:00Z" "2026-11-09T09:01:00Z")")
  done
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-sales-tool" "${sales_runs[@]}"

  local ops_runs=()
  for i in 101 102 103 104 105 106 107 108 109; do
    ops_runs+=("$(_ciqm_run_obj "$i" Benjis-Plants/benjis-ops-tool "CI" pull_request "feature-$i" success "2026-11-10T09:00:00Z" "2026-11-10T09:01:00Z")")
  done
  _ciqm_write_completed "$fixdir" "Benjis-Plants/benjis-ops-tool" "${ops_runs[@]}"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$(printf '%s' "$out" | jq '.ci_metrics.pass_rate_pct')" "90" "the overall rate is 90% (9 of 10 TODAY-eligible runs), not the 47% a naive n-weighted average of the per-category rates would give" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.ci_metrics.pass_rate_n')" "10" "overall eligible count is 10 (1 today failure + 9 today successes), excluding the 9 prior-day successes" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.ci_health')" "ok" "90% overall is above the 80% threshold -> ok (the bug this guards against would read degraded)" || return 1
}

# ---- AC: a metrics snapshot stale past CI_QUEUE_DOWN_STALE_CYCLES * its own interval -> down ----
test_ciqm_ac_stale_metrics_snapshot_is_down() {
  local pipe fixdir reposfile out
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1   # online runners -- proves this isn't the zero-runners leg

  # A real, successful prior metrics snapshot, backdated past the 3 * 900s = 2700s threshold.
  echo '{"as_of":"2026-11-10T08:00:00Z","categories":[]}' > "$pipe/ci-metrics.json"
  python3 -c "import os,sys,time; t=time.time()-3000; os.utime(sys.argv[1], (t, t))" "$pipe/ci-metrics.json"
  cp "$pipe/ci-metrics.json" "$pipe/metrics-attempt"
  python3 -c "import os,sys,time; t=time.time()-3000; os.utime(sys.argv[1], (t, t))" "$pipe/metrics-attempt"

  # This cycle's own refetch also fails (malformed) -- the stale file must stay stale, not refreshed.
  echo '{}' > "$fixdir/runs-Benjis-Plants__benjis-sales-tool-completed.json"

  _ciqm_run "$pipe" "$fixdir" "$reposfile" >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$(printf '%s' "$out" | jq -r '.ci_health')" "down" "a metrics snapshot stale past 3 of its own 15-min cycles -> down" || return 1
}

# ---- AC (PR #713 review, MEDIUM — cold-start honesty): metrics enabled, never once succeeded, no
# prior $METRICS_OUT to check staleness against -> ci_health must still read "down" once the
# consecutive-failure streak reaches CI_QUEUE_DOWN_STALE_CYCLES, not silently "ok" forever just
# because there's no snapshot file yet.
test_ciqm_ac_cold_start_down_after_stale_cycles_with_no_prior_snapshot() {
  local pipe fixdir reposfile out health1 health3 metrics_file
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  _ciqm_repos_file "$reposfile" "Benjis-Plants/benjis-sales-tool"
  _ciqm_empty_queue_fixtures "$fixdir" "Benjis-Plants/benjis-sales-tool"
  _ciqm_online_runners "$fixdir" 1 1   # online + busy -- proves this isn't the zero-runners/stuck-queue leg
  echo '{}' > "$fixdir/runs-Benjis-Plants__benjis-sales-tool-completed.json"   # malformed every cycle, never succeeds

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  health1=$(printf '%s' "$out" | jq -r '.ci_health')

  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  _ciqm_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1794308400 >/dev/null
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  health3=$(printf '%s' "$out" | jq -r '.ci_health')
  metrics_file=$(cat "$pipe/ci-metrics.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"; rm -f "$reposfile"

  assert_eq "$metrics_file" "" "sanity: the collector really never once wrote a successful ci-metrics.json snapshot" || return 1
  # jq -r on a missing/non-string ci_health would print "null", not empty -- assert the real
  # expected value ("ok", not just "not down") so a broken/garbage value can't slip through.
  assert_eq "$health1" "ok" "a single metrics failure, with no prior snapshot, is not yet down (output: $health1)" || return 1
  assert_eq "$health3" "down" "3 consecutive metrics failures with no prior snapshot -> down (cold-start honesty)" || return 1
}

run_test test_ciqm_ac_duration_and_pass_rate_per_category
run_test test_ciqm_ac_null_conclusion_excluded_from_pass_rate_not_a_failure
run_test test_ciqm_ac_zero_runs_in_category_is_omitted
run_test test_ciqm_ac_dedup_by_id_across_the_scheduler_ops_tool_alias
run_test test_ciqm_ac_exactly_one_completed_call_per_repo
run_test test_ciqm_ac_all_runners_offline_is_down
run_test test_ciqm_ac_old_queued_job_with_zero_busy_is_degraded
run_test test_ciqm_ac_ok_when_nothing_is_wrong
run_test test_ciqm_ac_malformed_completed_response_keeps_previous_snapshot
run_test test_ciqm_disabled_by_default_adds_zero_calls_and_no_key
run_test test_ciqm_own_throttle_skips_a_not_yet_due_cycle
run_test test_ciqm_ac_long_duration_clamped_keeps_category_present
run_test test_ciqm_ac_cancelled_and_skipped_excluded_not_counted_as_failures
run_test test_ciqm_ac_category_with_only_cancelled_skipped_is_omitted
run_test test_ciqm_ac_cancelled_run_excluded_from_average_duration
run_test test_ciqm_ac_prior_day_success_still_counts_toward_duration
run_test test_ciqm_obs_sentry_capture_on_malformed_completed_response
run_test test_ciqm_ac_missing_timestamp_aborts_keeps_previous_snapshot
run_test test_ciqm_obs_slack_only_on_third_consecutive_metrics_failure
run_test test_ciqm_ac_low_pass_rate_is_degraded
run_test test_ciqm_ac_overall_rate_not_weighted_by_stale_category_n
run_test test_ciqm_ac_stale_metrics_snapshot_is_down
run_test test_ciqm_ac_cold_start_down_after_stale_cycles_with_no_prior_snapshot
