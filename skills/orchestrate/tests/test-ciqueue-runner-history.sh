# Issue #648 — exclude offline runners from busy/total, and per-runner utilization history
# (runners_offline, ci_queue.runners[], the append-only $PIPE/ci-runner-samples.jsonl stream and
# its 24h/72h rollup). No live network calls: `gh api` is replaced by the collector's own
# CI_QUEUE_FIXTURE_DIR/CI_QUEUE_FIXTURE_FAIL seam (same as test-ciqueue-collector.sh); CI_QUEUE_NOW
# freezes "now" so the window/prune math is deterministic.
#
# CORRECTED KEYING (post-BLOCKED ruling on the issue): live evidence showed GitHub runner `id`s are
# NOT stable across a slot's re-registration — every ephemeral job mints a new id AND a new name
# suffix together; only a dead/offline registration keeps an old id. History and `runners[]` are
# therefore keyed by SLOT (the name with its trailing `-[0-9]+` suffix stripped), not by id. Runner
# names below deliberately use distinct multi-segment slot prefixes (e.g. "gha-aa-11", not "gha-11")
# so that stripping each one's trailing numeric suffix does NOT collapse unrelated test runners
# into the same slot.
#
# Safe to source into run-tests.sh's shared shell: no top-level `exit`, every helper prefixed
# _ciqrh_, every test function declares its own locals.

HERE_CIQRH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT_CIQRH=$(cd "$HERE_CIQRH/../../.." && pwd)
COLLECTOR_CIQRH="$REPO_ROOT_CIQRH/infra/ci-runners/ci-queue-collect.sh"
CIQRH_REPO="example-owner/ci-runner-history"
CIQRH_SAFE="example-owner__ci-runner-history"

# _ciqrh_repos_file <dir> -> prints a path to a repos file listing exactly $CIQRH_REPO, plus the
# fixtures for its (empty) queued/in_progress run lists, so every cycle's call count is fixed
# (2 runner-list calls + 2 run-list calls = 4) regardless of how many runners are in play —
# isolates the runner-counting/history work (this ticket) from the queue-depth work (#643).
_ciqrh_repos_file() {
  local dir=$1
  local f="$dir/repos.txt"
  printf '%s\n' "$CIQRH_REPO" > "$f"
  echo '{"workflow_runs":[]}' > "$dir/runs-${CIQRH_SAFE}-queued.json"
  echo '{"workflow_runs":[]}' > "$dir/runs-${CIQRH_SAFE}-in_progress.json"
  printf '%s' "$f"
}

# _ciqrh_run <pipe> <fixdir> <reposfile> [extra env...] -> runs one forced cycle; sets
# CIQRH_OUT/CIQRH_CALLS, returns the collector's exit code.
_ciqrh_run() {
  local pipe=$1 fixdir=$2 reposfile=$3; shift 3
  ( CI_QUEUE_FORCE=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" \
    CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" \
    CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_REPOS_FILE="$reposfile" \
    CI_QUEUE_FIXTURE_DIR="$fixdir" \
    env "$@" bash "$COLLECTOR_CIQRH" )
  local rc=$?
  CIQRH_OUT=$(cat "$pipe/status-ci.json" 2>/dev/null)
  CIQRH_CALLS=$(cat "$pipe/calls.log" 2>/dev/null)
  return "$rc"
}

# _ciqrh_runners_fixture <dir> <org-runners-json> — repo-level runner list is always empty here
# (jpmoya/claude-agents isn't part of this suite's scenario); everything lives in the org list.
_ciqrh_runners_fixture() {
  printf '%s' "$2" > "$1/runners-org.json"
  echo '{"total_count":0,"runners":[]}' > "$1/runners-repo.json"
}

# ---- AC1: online-only counting + runners_offline, incl. the real shared-slot dup scenario -------

test_ciqrh_ac1_online_only_counting_and_runners_offline() {
  local pipe fixdir reposfile rc out
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")
  # Mirrors the live bug exactly: 6 registrations, 5 online (3 busy) + 1 offline. The offline one
  # (id 6, "gha-ee-6") is a stale duplicate SHARING A SLOT with id 55 ("gha-ee-55", online,
  # labeled prod_deploy) — the slot's lower-id registration is the dead one, exactly like the live
  # evidence (dead id 15077 < live id 15686). runners_busy/total/offline stay counted per
  # REGISTRATION (unaffected by slot-keying), but runners[] must collapse the shared slot to ONE
  # entry (5 slots, not 6 registrations), reporting the LIVE (higher-id) registration's identity.
  _ciqrh_runners_fixture "$fixdir" '{"total_count":6,"runners":[
    {"id":1,"name":"gha-aa-1","status":"online","busy":true,"labels":[{"name":"self-hosted"},{"name":"benjis-ci"}]},
    {"id":2,"name":"gha-bb-2","status":"online","busy":true,"labels":[{"name":"self-hosted"},{"name":"benjis-ci"}]},
    {"id":3,"name":"gha-cc-3","status":"online","busy":true,"labels":[{"name":"self-hosted"},{"name":"benjis-ci"}]},
    {"id":4,"name":"gha-dd-4","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"benjis-ci"}]},
    {"id":6,"name":"gha-ee-6","status":"offline","busy":false,"labels":[{"name":"self-hosted"},{"name":"benjis-ci"}]},
    {"id":55,"name":"gha-ee-55","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"benjis-ci-prod-deploy"}]}
  ]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1700000000; rc=$?
  out=$CIQRH_OUT
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "AC1: cycle exits 0" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.runners_busy')" "3" "AC1: runners_busy counts only online+busy registrations (3)" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.runners_total')" "5" "AC1: runners_total counts only the 5 online registrations, not 6" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.runners_offline')" "1" "AC1: runners_offline is exactly 1" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.runners | length')" "5" "AC1: runners[] has one entry per SLOT (5), not one per registration (6) — the dead dup collapses into its live sibling's slot" || return 1
  assert_eq "$(printf '%s' "$out" | jq -c '.runners[] | select(.name=="gha-ee-55") | {id,online,busy,role}')" \
    '{"id":55,"online":true,"busy":false,"role":"prod_deploy"}' \
    "AC1: the shared slot reports online=true (its live registration) and the live/higher-id registration's id+role, not the dead one's" || return 1
  assert_eq "$(printf '%s' "$out" | jq '[.runners[] | select(.id==6)] | length')" "0" "AC1: the dead registration's own id never surfaces as a separate runners[] entry" || return 1
}

test_ciqrh_ac9_zero_new_api_calls() {
  local pipe fixdir reposfile calls
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")
  _ciqrh_runners_fixture "$fixdir" '{"total_count":6,"runners":[
    {"id":1,"name":"gha-aa-1","status":"online","busy":true},
    {"id":2,"name":"gha-bb-2","status":"online","busy":true},
    {"id":3,"name":"gha-cc-3","status":"online","busy":true},
    {"id":4,"name":"gha-dd-4","status":"online","busy":false},
    {"id":5,"name":"gha-ee-5","status":"online","busy":false},
    {"id":6,"name":"gha-ff-6-stale","status":"offline","busy":false}
  ]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1700000000
  calls=$CIQRH_CALLS
  rm -rf "$pipe" "$fixdir"

  # 2 (runner lists: org + self-repo) + 2 (this one repo's queued + in_progress lists) = 4,
  # unchanged from the #643 baseline formula regardless of runner count/history processing.
  assert_eq "$calls" "4" "AC9: the runner-counting/history change adds zero new gh api calls" || return 1
}

# ---- AC2: runners[] identity, including the missing-status/busy negative case -------------------

test_ciqrh_ac2_runners_array_identity_and_negative_case() {
  local pipe fixdir reposfile out r1 r2 r3
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")
  _ciqrh_runners_fixture "$fixdir" '{"total_count":3,"runners":[
    {"id":11,"name":"gha-aa-11","status":"online","busy":true,"labels":[{"name":"benjis-ci"}]},
    {"id":12,"name":"gha-bb-12","status":"offline","busy":false,"labels":[{"name":"benjis-ci"}]},
    {"id":13,"name":"gha-cc-13","labels":[{"name":"benjis-ci"}]}
  ]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1700000000
  out=$CIQRH_OUT
  r1=$(printf '%s' "$out" | jq -c '.runners[] | select(.id==11) | {id,name,online,busy,role}')
  r2=$(printf '%s' "$out" | jq -c '.runners[] | select(.id==12) | {id,name,online,busy,role}')
  r3=$(printf '%s' "$out" | jq -c '.runners[] | select(.id==13) | {id,name,online,busy,role}')
  rm -rf "$pipe" "$fixdir"

  assert_eq "$r1" '{"id":11,"name":"gha-aa-11","online":true,"busy":true,"role":"general"}' "AC2: online+busy runner reported correctly" || return 1
  assert_eq "$r2" '{"id":12,"name":"gha-bb-12","online":false,"busy":false,"role":"general"}' "AC2: offline runner still has an entry, busy forced false" || return 1
  assert_eq "$r3" '{"id":13,"name":"gha-cc-13","online":false,"busy":false,"role":"general"}' "AC2 negative case: missing status/busy -> offline/not-busy, cycle does not crash" || return 1
}

test_ciqrh_prod_deploy_role_surfaced() {
  local pipe fixdir reposfile out role_prod role_general
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")
  _ciqrh_runners_fixture "$fixdir" '{"total_count":2,"runners":[
    {"id":21,"name":"gha-prod-21","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"benjis-ci-prod-deploy"}]},
    {"id":22,"name":"gha-general-22","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"benjis-ci"}]}
  ]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1700000000
  out=$CIQRH_OUT
  role_prod=$(printf '%s' "$out" | jq -r '.runners[] | select(.id==21) | .role')
  role_general=$(printf '%s' "$out" | jq -r '.runners[] | select(.id==22) | .role')
  rm -rf "$pipe" "$fixdir"

  assert_eq "$role_prod" "prod_deploy" "the benjis-ci-prod-deploy-labeled runner is surfaced with role=prod_deploy" || return 1
  assert_eq "$role_general" "general" "a plain benjis-ci runner is role=general" || return 1
}

# ---- AC3 (corrected): samples keyed by SLOT, surviving a re-registration where BOTH id AND the
# name's numeric suffix change (the id-keyed design's literal "only name changed" scenario never
# happens in practice — every ephemeral job mints a new id and a new name suffix together). -------

test_ciqrh_ac3_samples_keyed_by_slot_survive_an_id_and_name_change() {
  local pipe fixdir reposfile samples slots runners_len id_cycle2 name_cycle2 util24
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")

  # Exactly the live scenario from the issue's evidence: same slot prefix
  # "gha-CI-ubuntu-8gb-ash-2-1", but id 42->99 AND the name's numeric suffix 29555->3218 both
  # change together between cycles.
  _ciqrh_runners_fixture "$fixdir" '{"total_count":1,"runners":[{"id":42,"name":"gha-CI-ubuntu-8gb-ash-2-1-29555","status":"online","busy":false}]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1700000000

  _ciqrh_runners_fixture "$fixdir" '{"total_count":1,"runners":[{"id":99,"name":"gha-CI-ubuntu-8gb-ash-2-1-3218","status":"online","busy":true}]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1700000240   # one INTERVAL (240s default) later

  samples=$(cat "$pipe/ci-runner-samples.jsonl" 2>/dev/null)
  slots=$(printf '%s\n' "$samples" | jq -r '.slot' | sort -u | tr '\n' ',')
  runners_len=$(printf '%s' "$CIQRH_OUT" | jq '.runners | length')
  id_cycle2=$(printf '%s' "$CIQRH_OUT" | jq '.runners[0].id')
  name_cycle2=$(printf '%s' "$CIQRH_OUT" | jq -r '.runners[0].name')
  util24=$(printf '%s' "$CIQRH_OUT" | jq '.runners[0].util_24h_pct')
  rm -rf "$pipe" "$fixdir"

  assert_eq "$(printf '%s\n' "$samples" | sed '/^$/d' | wc -l | tr -d ' ')" "2" "AC3: 2 cycles -> 2 sample lines total" || return 1
  assert_eq "$slots" "gha-CI-ubuntu-8gb-ash-2-1," "AC3: both sample lines keyed by the same slot despite id AND name both changing" || return 1
  assert_eq "$runners_len" "1" "AC3: id-keying would report 2 entries (the old id lingering + the new id); slot-keying reports exactly 1" || return 1
  assert_eq "$id_cycle2" "99" "AC3: runners[] reports the current (new) id" || return 1
  assert_eq "$name_cycle2" "gha-CI-ubuntu-8gb-ash-2-1-3218" "AC3: runners[] reports the current (new) name" || return 1
  assert_eq "$util24" "0" "AC3: utilization carries over from cycle 1's sample (busy=false) despite the id/name change -> 0, not null (id-keying would show null here, since id 99 has no history of its own)" || return 1
}

# ---- AC4: pruning -------------------------------------------------------------------------------

test_ciqrh_ac4_pruning_removes_stale_lines() {
  local pipe fixdir reposfile now before after
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")
  now=1700000000
  # One fresh line (within 72h) and one stale line (73h ago — past 72h + the 240s buffer).
  printf '{"ts":%d,"slot":"gha-slot-1","id":1,"name":"gha-slot-1","online":true,"busy":false,"role":"general"}\n' "$((now - 3600))" > "$pipe/ci-runner-samples.jsonl"
  printf '{"ts":%d,"slot":"gha-slot-2","id":2,"name":"gha-slot-2","online":true,"busy":false,"role":"general"}\n' "$((now - 73 * 3600))" >> "$pipe/ci-runner-samples.jsonl"
  before=$(wc -l < "$pipe/ci-runner-samples.jsonl" | tr -d ' ')

  _ciqrh_runners_fixture "$fixdir" '{"total_count":0,"runners":[]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW="$now"
  after=$(grep -c '"slot":"gha-slot-2"' "$pipe/ci-runner-samples.jsonl" 2>/dev/null || true)
  local slot1_count; slot1_count=$(grep -c '"slot":"gha-slot-1"' "$pipe/ci-runner-samples.jsonl")
  rm -rf "$pipe" "$fixdir"

  assert_eq "$before" "2" "sanity: 2 seeded lines before the cycle" || return 1
  assert_eq "${after:-0}" "0" "AC4: the 73h-old line (gha-slot-2) is pruned away" || return 1
  assert_eq "$slot1_count" "1" "AC4: the fresh 1h-old line (gha-slot-1) survives pruning" || return 1
}

# ---- AC5: utilization math ----------------------------------------------------------------------

# _ciqrh_seed_samples <file> <now> <slot> <id> <secs-ago-list> <busy-list> — one sample per pair of
# (seconds-ago, busy) at the given slot; busy-list entries are "true"/"false". Seconds, not hours,
# so a sub-hour offset (the AC5 "gap" case) never needs float bash arithmetic.
_ciqrh_seed_samples() {
  local file=$1 now=$2 slot=$3 id=$4; shift 4
  local secs=$1 busys=$2 i s b
  : > "$file.tmp"; [ -e "$file" ] && cat "$file" > "$file.tmp"
  local -a ss bs
  IFS=',' read -ra ss <<< "$secs"
  IFS=',' read -ra bs <<< "$busys"
  for i in "${!ss[@]}"; do
    s=${ss[$i]}; b=${bs[$i]}
    printf '{"ts":%d,"slot":"%s","id":%d,"name":"%s","online":true,"busy":%s,"role":"general"}\n' \
      "$((now - s))" "$slot" "$id" "$slot" "$b" >> "$file.tmp"
  done
  mv "$file.tmp" "$file"
}

test_ciqrh_ac5_exact_utilization_6_of_10_is_60_pct() {
  local pipe fixdir reposfile now out u24
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")
  now=1700000000
  # 10 samples inside the last 24h (spaced with a deliberate gap between 3h-ago and 20h-ago —
  # AC5's "a gap in samples doesn't lower the percentage" case), 6 busy / 4 not -> round(600/10)=60.
  _ciqrh_seed_samples "$pipe/ci-runner-samples.jsonl" "$now" "gha-r99" 99 \
    "3600,7200,10800,72000,75600,79200,82800,84600,85320,85860" "true,true,true,false,false,false,true,true,true,false"
  _ciqrh_runners_fixture "$fixdir" '{"total_count":1,"runners":[{"id":99,"name":"gha-r99-5001","status":"online","busy":false}]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW="$now"
  out=$CIQRH_OUT
  u24=$(printf '%s' "$out" | jq '.runners[] | select(.id==99) | .util_24h_pct')
  rm -rf "$pipe" "$fixdir"

  assert_eq "$u24" "60" "AC5: 6 of 10 prior samples busy -> util_24h_pct is exactly 60 (denominator is sample count, not wall-clock hours)" || return 1
}

test_ciqrh_ac5_72h_window_differs_from_24h() {
  local pipe fixdir reposfile now out u24 u72
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")
  now=1700000000
  # Inside 24h: 2 samples, both busy -> 100%. Add 2 more samples between 24h and 72h, both NOT
  # busy -> the 72h window (4 samples, 2 busy) must read 50%, distinctly different from 24h's 100%.
  _ciqrh_seed_samples "$pipe/ci-runner-samples.jsonl" "$now" "gha-r55" 55 "3600,7200,108000,144000" "true,true,false,false"
  _ciqrh_runners_fixture "$fixdir" '{"total_count":1,"runners":[{"id":55,"name":"gha-r55-5002","status":"online","busy":false}]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW="$now"
  out=$CIQRH_OUT
  u24=$(printf '%s' "$out" | jq '.runners[] | select(.id==55) | .util_24h_pct')
  u72=$(printf '%s' "$out" | jq '.runners[] | select(.id==55) | .util_72h_pct')
  rm -rf "$pipe" "$fixdir"

  assert_eq "$u24" "100" "util_24h_pct only sees the 2 within-24h samples (both busy) -> 100" || return 1
  assert_eq "$u72" "50" "util_72h_pct sees all 4 within-72h samples (2 busy) -> 50" || return 1
}

test_ciqrh_ac5_rounding_not_truncating_2_of_3_is_67_pct() {
  local pipe fixdir reposfile now out u24
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")
  now=1700000000
  # 2 of 3 busy -> 66.666...% ; round() must yield 67, never truncate()'s 66. (A case like 1 of 3
  # -> 33.33% would pass under truncation too, so it doesn't distinguish the two — this one does.)
  _ciqrh_seed_samples "$pipe/ci-runner-samples.jsonl" "$now" "gha-r33" 33 "3600,7200,10800" "true,true,false"
  _ciqrh_runners_fixture "$fixdir" '{"total_count":1,"runners":[{"id":33,"name":"gha-r33-5003","status":"online","busy":false}]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW="$now"
  out=$CIQRH_OUT
  u24=$(printf '%s' "$out" | jq '.runners[] | select(.id==33) | .util_24h_pct')
  rm -rf "$pipe" "$fixdir"

  assert_eq "$u24" "67" "AC5 rounding: 2 of 3 busy (66.67%) rounds to 67, not truncated to 66" || return 1
}

# ---- AC6 (corrected): zero samples in 72h ages the SLOT out; a lingering (recently-deregistered)
# slot does not. --------------------------------------------------------------------------------

test_ciqrh_ac6_ages_out_with_zero_samples_in_72h() {
  local pipe fixdir reposfile now out
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")
  now=1700000000
  # This slot's only samples are 80h old (older than the 72h window) and it's no longer returned
  # by the API (deregistered) -> must be entirely absent from runners[].
  _ciqrh_seed_samples "$pipe/ci-runner-samples.jsonl" "$now" "gha-slot-77" 77 "288000,291600" "true,false"
  _ciqrh_runners_fixture "$fixdir" '{"total_count":0,"runners":[]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW="$now"
  out=$CIQRH_OUT
  rm -rf "$pipe" "$fixdir"

  assert_eq "$(printf '%s' "$out" | jq '[.runners[] | select(.id==77)] | length')" "0" "AC6: a slot with zero samples anywhere in the last 72h ages out of runners[]" || return 1
}

test_ciqrh_ac6_lingers_while_a_recent_sample_exists_despite_deregistration() {
  local pipe fixdir reposfile now out entry
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")
  now=1700000000
  # This slot has a 1h-old sample (well inside 72h) but is no longer in the current API response —
  # contrast case proving runners[] isn't simply "whatever the API returns this cycle": it still
  # shows up, using its last-known identity, with online/busy false (it's not being seen anymore).
  _ciqrh_seed_samples "$pipe/ci-runner-samples.jsonl" "$now" "gha-slot-88" 88 "3600" "true"
  _ciqrh_runners_fixture "$fixdir" '{"total_count":0,"runners":[]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW="$now"
  out=$CIQRH_OUT
  entry=$(printf '%s' "$out" | jq -c '.runners[] | select(.id==88) | {id,name,online,busy}')
  rm -rf "$pipe" "$fixdir"

  assert_eq "$entry" '{"id":88,"name":"gha-slot-88","online":false,"busy":false}' "a recently-deregistered slot still inside its 72h window lingers with last-known identity, reported offline/not-busy" || return 1
}

# ---- AC7: a brand-new runner reports null, not 0/100 ---------------------------------------------

test_ciqrh_ac7_newly_seen_runner_reports_null() {
  local pipe fixdir reposfile out entry
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir")
  _ciqrh_runners_fixture "$fixdir" '{"total_count":1,"runners":[{"id":66,"name":"gha-r66-5004","status":"online","busy":true}]}'
  _ciqrh_run "$pipe" "$fixdir" "$reposfile" CI_QUEUE_NOW=1700000000
  out=$CIQRH_OUT
  entry=$(printf '%s' "$out" | jq -c '.runners[] | select(.id==66) | {util_24h_pct,util_72h_pct}')
  rm -rf "$pipe" "$fixdir"

  assert_eq "$entry" '{"util_24h_pct":null,"util_72h_pct":null}' "AC7: a runner seen for the first time this cycle reports null, not 0 or 100" || return 1
}

# ---- Observability: a failure in the sample-write step is reported like any other failure --------

test_ciqrh_obs_sample_write_failure_reports_to_sentry() {
  local pipe fixdir reposfile bindir body
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqrh_repos_file "$fixdir"); bindir=$(mktemp -d)
  cat > "$bindir/curl" <<'EOF'
#!/bin/bash
echo "CALL $*" >> "$(dirname "$0")/calls"
exit 0
EOF
  chmod +x "$bindir/curl"
  _ciqrh_runners_fixture "$fixdir" '{"total_count":1,"runners":[{"id":1,"name":"gha-aa-1","status":"online","busy":false}]}'
  # A samples "file" that is actually a pre-existing directory: mkdir -p on its dirname succeeds,
  # but mktemp "$SAMPLES_FILE.XXXXXX" / the final mv both fail against a directory target —
  # forces the new sample-write step to fail without touching live Sentry.
  mkdir -p "$pipe/ci-runner-samples.jsonl"
  ( CI_QUEUE_FORCE=1 CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_REPOS_FILE="$reposfile" CI_QUEUE_FIXTURE_DIR="$fixdir" \
    SENTRY_DSN="https://testkey@sentry.test/42" \
    PATH="$bindir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    bash "$COLLECTOR_CIQRH" )
  body=$(grep "sentry.test" "$bindir/calls" 2>/dev/null)
  rm -rf "$pipe" "$fixdir" "$bindir"

  assert_contains "$body" "route\":\"ci-queue/collect\"" "Observability: a sample-write failure still reports via the existing Sentry seam (route=ci-queue/collect)" || return 1
}

run_test test_ciqrh_ac1_online_only_counting_and_runners_offline
run_test test_ciqrh_ac9_zero_new_api_calls
run_test test_ciqrh_ac2_runners_array_identity_and_negative_case
run_test test_ciqrh_prod_deploy_role_surfaced
run_test test_ciqrh_ac3_samples_keyed_by_slot_survive_an_id_and_name_change
run_test test_ciqrh_ac4_pruning_removes_stale_lines
run_test test_ciqrh_ac5_exact_utilization_6_of_10_is_60_pct
run_test test_ciqrh_ac5_72h_window_differs_from_24h
run_test test_ciqrh_ac5_rounding_not_truncating_2_of_3_is_67_pct
run_test test_ciqrh_ac6_ages_out_with_zero_samples_in_72h
run_test test_ciqrh_ac6_lingers_while_a_recent_sample_exists_despite_deregistration
run_test test_ciqrh_ac7_newly_seen_runner_reports_null
run_test test_ciqrh_obs_sample_write_failure_reports_to_sentry
