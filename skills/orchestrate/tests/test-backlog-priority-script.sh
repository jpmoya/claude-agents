# backlog-priority.sh — JP's drag-and-reorder priority store (status page "Backlog priority"
# section). Source of truth is a machine-managed GitHub registry issue (label
# backlog-priority-registry) in $GOAL_REGISTRY_REPO; $PIPE/backlog-priority.json is the host-local
# cache (same pattern as the goal registry, goal-lib.sh line 3).
#
# Covers: `set` validates every key, creates the registry issue on first use, writes the registry
# issue body and the local cache; `pull` refreshes the local cache from the registry issue body and
# never fails the pass on a missing/corrupt body; a malformed key is rejected before any gh call.

BP_HERE_T=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# bp_env — fresh PIPE/HOME/bin dir with a self-contained fake `gh` standing in for the registry repo.
# State files under $BP_D: registry-number (the current registry issue number, "" until created),
# registry-body-<n> (that issue's current body), create-calls (count of `api -X POST .../issues`).
bp_env() {
  BP_PIPE=$(new_pipe); BP_HOME=$(new_home); BP_D="$BP_HOME/.local/bin"; mkdir -p "$BP_D"
  : > "$BP_D/registry-number"; : > "$BP_D/create-calls"
  cat > "$BP_D/gh" <<'GH_EOF'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$D/gh-calls.log"
n=$(cat "$D/registry-number" 2>/dev/null)
case "$*" in
  "issue list --repo "*"--label backlog-priority-registry"*)
    if [ -n "$n" ]; then jq -rn --argjson n "$n" '$n|tostring'; fi
    exit 0 ;;
  "api -X POST "*"/labels"*"name=backlog-priority-registry"*)
    exit 0 ;;
  "api -X POST "*"/issues"*"--input -"*"--jq .number"*)
    body=$(cat)
    newn=$(( $(cat "$D/last-number" 2>/dev/null || echo 100) + 1 ))
    echo "$newn" > "$D/last-number"
    echo "$newn" > "$D/registry-number"
    printf '%s' "$body" | jq -r '.body' > "$D/registry-body-$newn"
    echo "1" >> "$D/create-calls"
    echo "$newn"
    exit 0 ;;
  "issue view "*"--repo "*"--json body --jq .body"*)
    vn=$(printf '%s' "$*" | sed -n 's/^issue view \([0-9][0-9]*\) .*/\1/p')
    cat "$D/registry-body-$vn" 2>/dev/null
    exit 0 ;;
  "api -X PATCH "*"/issues/"*"--input -"*)
    pn=$(printf '%s' "$*" | sed -n 's#.*/issues/\([0-9][0-9]*\).*#\1#p')
    body=$(cat)
    printf '%s' "$body" | jq -r '.body' > "$D/registry-body-$pn"
    exit 0 ;;
  *) echo "fake gh (backlog-priority): unexpected: $*" >&2; exit 1 ;;
esac
GH_EOF
  chmod +x "$BP_D/gh"
  : > "$BP_D/gh-calls.log"
}

bp_run() {  # bp_run <subcommand...> — runs backlog-priority.sh with isolated HOME/PIPE/PATH
  HOME="$BP_HOME" PIPE="$BP_PIPE" PATH="$BP_D:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    GOAL_REGISTRY_REPO="jpmoya/claude-agents" \
    /bin/bash "$BP_HERE_T/../backlog-priority.sh" "$@"
}

bp_cleanup() { rm -rf "$BP_PIPE" "$BP_HOME"; }

test_bp_set_rejects_malformed_key() {
  bp_env
  local out rc
  out=$(bp_run set 'not-a-valid-key' 2>&1); rc=$?
  bp_cleanup
  assert_eq "$rc" "1" "malformed key: non-zero exit" || return 1
  assert_contains "$out" "malformed key" "malformed key: error message" || return 1
}

test_bp_set_rejects_one_bad_key_among_good_ones() {
  bp_env
  local out rc
  out=$(bp_run set 'owner/repo#1' 'owner/repo' 'owner/repo#2'); rc=$?
  bp_cleanup
  assert_eq "$rc" "1" "one malformed key among good ones still refuses" || return 1
}

test_bp_set_creates_registry_issue_once_and_writes_body_and_cache() {
  bp_env
  bp_run set 'owner/repo#5' 'owner/repo#2' >/dev/null
  local body cache calls
  n=$(cat "$BP_D/registry-number")
  body=$(cat "$BP_D/registry-body-$n" 2>/dev/null)
  cache=$(cat "$BP_PIPE/backlog-priority.json" 2>/dev/null)
  calls=$(wc -l < "$BP_D/create-calls" | tr -d ' ')
  bp_cleanup
  assert_eq "$body" '["owner/repo#5","owner/repo#2"]' "registry issue body is the ordered key array" || return 1
  assert_eq "$cache" '{"owner/repo#5":0,"owner/repo#2":1}' "local cache is the rank map" || return 1
  assert_eq "$calls" "1" "registry issue created exactly once" || return 1
}

test_bp_set_dedupes_repeated_keys_keeping_first_position() {
  bp_env
  bp_run set 'owner/repo#1' 'owner/repo#2' 'owner/repo#1' >/dev/null
  local cache; cache=$(cat "$BP_PIPE/backlog-priority.json" 2>/dev/null)
  bp_cleanup
  assert_eq "$cache" '{"owner/repo#1":0,"owner/repo#2":1}' "a repeated key keeps its first position, not re-appended" || return 1
}

test_bp_set_reuses_existing_registry_issue() {
  bp_env
  bp_run set 'owner/repo#1' >/dev/null
  bp_run set 'owner/repo#1' 'owner/repo#2' >/dev/null
  local calls; calls=$(wc -l < "$BP_D/create-calls" | tr -d ' ')
  bp_cleanup
  assert_eq "$calls" "1" "a second set reuses the same registry issue, never creates a second one" || return 1
}

test_bp_pull_refreshes_local_cache_from_registry_body() {
  bp_env
  bp_run set 'owner/repo#9' 'owner/repo#1' >/dev/null
  rm -f "$BP_PIPE/backlog-priority.json"   # simulate a fresh host that only ever pulls
  bp_run pull >/dev/null
  local cache; cache=$(cat "$BP_PIPE/backlog-priority.json" 2>/dev/null)
  bp_cleanup
  assert_eq "$cache" '{"owner/repo#9":0,"owner/repo#1":1}' "pull rebuilds the local cache from the registry issue" || return 1
}

test_bp_pull_on_no_registry_issue_yet_is_a_silent_empty_cache() {
  bp_env
  local out rc
  out=$(bp_run pull); rc=$?
  local cache; cache=$(cat "$BP_PIPE/backlog-priority.json" 2>/dev/null)
  bp_cleanup
  assert_eq "$rc" "0" "pull with nothing registered yet still exits 0" || return 1
  assert_eq "$cache" '{}' "cache defaults to {} (today's fallback order applies for every ticket)" || return 1
}

run_test test_bp_set_rejects_malformed_key
run_test test_bp_set_rejects_one_bad_key_among_good_ones
run_test test_bp_set_creates_registry_issue_once_and_writes_body_and_cache
run_test test_bp_set_dedupes_repeated_keys_keeping_first_position
run_test test_bp_set_reuses_existing_registry_issue
run_test test_bp_pull_refreshes_local_cache_from_registry_body
run_test test_bp_pull_on_no_registry_issue_yet_is_a_silent_empty_cache
