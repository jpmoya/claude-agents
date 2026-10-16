# Issue #312 — a JP go stays valid across agent-made plan revisions that do not change any [prod]
# step's production effect.
#
# Contract the tests pin (the ticket leaves the helper name to the implementation; this file fixes it):
#   agents/infra-operator.md carries ONE fenced bash function `go_inherit <N>` (same pattern as
#   `jp_go` in orchestrator.md, #303). It reads, via `gh api repos/{owner}/{repo}/issues/<N>` (author:
#   `.user.login`) and `.../issues/<N>/comments?per_page=100 --paginate`:
#     rc 0  stdout `go inherited: prod effect unchanged`  (a later PLAN PASS passes (a)-(d)), or the go
#           is dated after the LATEST PLAN PASS (nothing to inherit; old rule; never "fresh go required")
#     rc 1  stdout `fresh go required: <which>` — <which> quotes the changed/added `Prod effect:` text
#           (or says missing / edited / no go); the operator then posts AWAITING GO listing it
#     rc 2  failed read: no "go inherited" output
#   Every rc 0/1 outcome appends ONE line to the file "$SLOG" containing `validate`, the repo ($REPO),
#   the issue number and the reason; first line of the reason only, no plan/comment bodies, no secrets.
#   Rules (ticket "Decided rule" + PM clarifications): go = comment by issue author, first line `go`
#   (any case) or `**[jp] GO**`; go-time plan = plan body of the latest PLAN PASS created before the go
#   (the newest `[infra-planner] PLAN READY` before that PASS); every later PLAN PASS is compared
#   pairwise through the chain: `Prod effect:` lines (one per `[prod]` step) identical after whitespace
#   normalisation, no added [prod] step, no new JP-only step; a plan comment edited after creation
#   (updated_at > created_at) or missing `Prod effect:` lines in either plan => fresh go (fail closed).
#
#   AC1 positive/negative fixtures      AC2 validate log line     AC3 planner/reviewer text
#   AC4 other gates untouched           AC5 refusal logged (repo, issue, reason, no bodies)
#
# gh is a shell-function stub serving fixture JSON (real jq applies any --jq filter).
# Helpers/vars prefixed gi_ / GI_ (all test files share one shell).

HERE_GI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_GI=$(cd "$HERE_GI/../../.." && pwd)
OP_GI="$ROOT_GI/agents/infra-operator.md"
PL_GI="$ROOT_GI/agents/infra-planner.md"
RV_GI="$ROOT_GI/agents/infra-reviewer.md"
ORCH_GI="$ROOT_GI/agents/orchestrator.md"

GI_P1='target=vercel project benjis-prod; env=prod; data=DNS A record for example.test; irreversible=no'

gi_extract() {
  awk '
    /^```/ { inb = !inb; on = 0; next }
    inb && !on && ($0 ~ /^[[:space:]]*go_inherit[[:space:]]*\(\)/ || $0 ~ /^[[:space:]]*function[[:space:]]+go_inherit/) { on = 1 }
    inb && on { print; if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) exit }
  ' "$OP_GI"
}

# gi_plan <prod1-effect|""> <extra-steps> <staging-variant: a|b> <rollback-note> — a PLAN READY body
gi_plan() {
  local p1=$1 extra=$2 variant=$3 rb=$4 s_a s_b
  s_a=$'### Step 1 — Lower TTL  [staging]\nDepends on: none\nCommand:\n```bash\nvercel dns add example.test @ A 1.2.3.4 --scope benjisops\n```\nRollback: '"$rb"
  s_b=$'### Step 2 — Add alias  [staging]\nDepends on: none\nCommand:\n```bash\nvercel alias set x y --scope benjisops\n```\nRollback: remove alias'
  printf '%s\n' '**[infra-planner] PLAN READY**' 'Goal: move host' 'Environments touched: both' '' '## Steps'
  if [ "$variant" = a ]; then printf '%s\n\n%s\n\n' "$s_a" "$s_b"; else printf '%s\n\n%s\n\n' "$s_b" "$s_a"; fi
  printf '%s\n' '### Step 3 — Flip prod DNS  [prod]' 'Depends on: Step 1' 'Command:' '```bash' 'curl -H "Authorization: Bearer SECRETSENTINEL" https://api.example.test/flip' '```'
  [ -n "$p1" ] && printf 'Prod effect: %s\n' "$p1"
  printf '%s\n' 'Rollback: flip back' ''
  [ -n "$extra" ] && printf '%s\n' "$extra"
  return 0
}

GI_EXTRA_PROD=$'### Step 4 — Add prod webhook  [prod]\nDepends on: Step 3\nCommand:\n```bash\ncurl -X POST https://api.example.test/hooks\n```\nProd effect: target=hooks api; env=prod; data=new webhook; irreversible=no\nRollback: delete hook\n'
GI_EXTRA_DELETE=$'### Step 4 — Purge old rows  [prod]\nDepends on: Step 3\nCommand:\n```bash\npsql -c "delete from quotes_old"\n```\nProd effect: target=prod db; env=prod; data=DELETE quotes_old rows; irreversible=yes\nRollback: none — rows gone\n'

# gi_add <dir> <login> <created> <updated> <body> — append one comment to the fixture array
gi_add() {
  local d=$1 n
  [ -f "$d/c.json" ] || printf '[]\n' > "$d/c.json"
  n=$(jq 'length' "$d/c.json")
  jq --arg u "$2" --arg c "$3" --arg up "$4" --arg b "$5" --argjson n "$n" \
    '. + [{html_url:("https://github.com/o/r/issues/9#issuecomment-"+($n|tostring)),created_at:$c,updated_at:$up,user:{login:$u},body:$b}]' \
    "$d/c.json" > "$d/c.tmp" && mv "$d/c.tmp" "$d/c.json"
}
gi_pass() { gi_add "$1" jpmoya "$2" "$2" $'**[infra-reviewer] PLAN PASS**\nOK'; }   # PASS is posted under the issue owner's token in this repo; first line is the marker
gi_ready() { gi_add "$1" jpmoya "$2" "${4:-$2}" "$3"; }
gi_go() { gi_add "$1" "${3:-jpmoya}" "$2" "$2" "${4:-go}"; }

# gi_base <dir> — READY#1, PASS#1, go (10:10); callers append the revision(s)
gi_base() {
  local d=$1
  printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
  gi_ready "$d" 2026-10-16T10:00:00Z "$(gi_plan "$GI_P1" "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:05:00Z
  gi_go "$d" 2026-10-16T10:10:00Z
}

# gi_run <dir> [mode] — prints stdout, then RC=<n>, then LOG=<log contents>
gi_run() {
  local d=$1 mode=${2:-ok} code
  code=$(gi_extract)
  [ -n "$code" ] || { printf 'NOHELPER\nRC=99\n'; return 0; }
  : > "$d/slog"
  (
    export GI_DIR="$d" GI_MODE="$mode" SLOG="$d/slog" REPO="o/r"
    gh() {
      local filter="" a prev=""
      for a in "$@"; do case "$prev" in --jq|-q) filter=$a ;; esac; prev=$a; done
      [ "$GI_MODE" = fail ] && return 1
      case "$*" in
        *comments*) if [ -n "$filter" ]; then jq -r "$filter" "$GI_DIR/c.json"; else cat "$GI_DIR/c.json"; fi ;;
        *issues/[0-9]*|*"issue view"*) if [ -n "$filter" ]; then jq -r "$filter" "$GI_DIR/issue.json"; else cat "$GI_DIR/issue.json"; fi ;;
        *) return 1 ;;
      esac
    }
    export -f gh 2>/dev/null
    eval "$code"
    out=$(go_inherit 9 2>/dev/null); rc=$?
    printf '%s\nRC=%s\n' "$out" "$rc"
  )
}
gi_out() { printf '%s\n' "$1" | sed '$d'; }
gi_rc() { printf '%s\n' "$1" | tail -1 | sed 's/^RC=//'; }
gi_log() { cat "$1/slog" 2>/dev/null; }

# gi_refused <dir> <label> <expect-in-stdout> [revision...] — shared negative assertion
gi_refused() {
  local d=$1 label=$2 want=$3 r
  r=$(gi_run "$d")
  assert_eq "$(gi_rc "$r")" "1" "$label: rc 1" || return 1
  assert_contains "$(gi_out "$r")" "fresh go required:" "$label: reason prefix" || return 1
  assert_contains "$(gi_out "$r")" "$want" "$label: names the cause" || return 1
  assert_not_contains "$(gi_out "$r")" "go inherited" "$label: not inherited" || return 1
}

# ---------------------------------------------------------------------------------------- AC1 positive

test_gi_ac1_positive_unchanged_prod_effect_inherits() {
  local d r p1b
  d=$(mktemp -d); gi_base "$d"
  p1b="target=vercel   project benjis-prod;  env=prod; data=DNS A record for example.test;   irreversible=no "   # whitespace-only difference
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "$p1b" "" b 'a reworded rollback note')"   # staging steps reordered
  gi_pass "$d" 2026-10-16T10:25:00Z
  r=$(gi_run "$d")
  assert_eq "$(gi_rc "$r")" "0" "AC1: rc 0" || return 1
  assert_eq "$(gi_out "$r")" "go inherited: prod effect unchanged" "AC1: reason line" || return 1
  rm -rf "$d"
}

test_gi_ac1_go_after_latest_pass_needs_no_inheritance_even_for_legacy_plan() {
  local d r
  d=$(mktemp -d)
  printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
  gi_ready "$d" 2026-10-16T10:00:00Z "$(gi_plan "" "" a 'flip back')"   # legacy plan: no Prod effect line
  gi_pass "$d" 2026-10-16T10:05:00Z
  gi_go "$d" 2026-10-16T10:10:00Z
  r=$(gi_run "$d")
  assert_eq "$(gi_rc "$r")" "0" "AC1: legacy plan, go after latest PASS still valid" || return 1
  assert_not_contains "$(gi_out "$r")" "fresh go required" "AC1: not refused" || return 1
  rm -rf "$d"
}

# ---------------------------------------------------------------------------------------- AC1 negative

test_gi_ac1_neg_changed_target_database() {
  local d
  d=$(mktemp -d); gi_base "$d"
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan 'target=vercel project benjis-prod-v2; env=prod; data=DNS A record for example.test; irreversible=no' "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:25:00Z
  gi_refused "$d" "AC1 changed target" "benjis-prod-v2" || return 1
  rm -rf "$d"
}

test_gi_ac1_neg_added_prod_step() {
  local d
  d=$(mktemp -d); gi_base "$d"
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "$GI_P1" "$GI_EXTRA_PROD" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:25:00Z
  gi_refused "$d" "AC1 added prod step" "new webhook" || return 1
  rm -rf "$d"
}

test_gi_ac1_neg_new_step_deleting_data() {
  local d
  d=$(mktemp -d); gi_base "$d"
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "$GI_P1" "$GI_EXTRA_DELETE" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:25:00Z
  gi_refused "$d" "AC1 deleting data" "DELETE quotes_old rows" || return 1
  rm -rf "$d"
}

test_gi_ac1_neg_plan_edited_by_non_agent() {
  local d
  d=$(mktemp -d); gi_base "$d"
  # identical Prod effect, but the comment was edited 10 minutes after its created_at
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "$GI_P1" "" b 'flip back')" 2026-10-16T10:30:00Z
  gi_pass "$d" 2026-10-16T10:25:00Z
  gi_refused "$d" "AC1 edited plan" "edited" || return 1
  rm -rf "$d"
}

test_gi_ac1_neg_go_from_non_author() {
  local d
  d=$(mktemp -d)
  printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
  gi_ready "$d" 2026-10-16T10:00:00Z "$(gi_plan "$GI_P1" "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:05:00Z
  gi_go "$d" 2026-10-16T10:10:00Z someone-else
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "$GI_P1" "" b 'flip back')"
  gi_pass "$d" 2026-10-16T10:25:00Z
  gi_refused "$d" "AC1 non-author go" "go" || return 1
  rm -rf "$d"
}

test_gi_ac1_neg_go_not_exactly_go() {
  local d body
  for body in 'go ahead' 'going to review' 'not go'; do
    d=$(mktemp -d)
    printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
    gi_ready "$d" 2026-10-16T10:00:00Z "$(gi_plan "$GI_P1" "" a 'flip back')"
    gi_pass "$d" 2026-10-16T10:05:00Z
    gi_go "$d" 2026-10-16T10:10:00Z jpmoya "$body"
    gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "$GI_P1" "" b 'flip back')"
    gi_pass "$d" 2026-10-16T10:25:00Z
    gi_refused "$d" "AC1 go body [$body]" "go" || return 1
    rm -rf "$d"
  done
}

test_gi_ac1_neg_missing_prod_effect_in_later_plan() {
  local d
  d=$(mktemp -d); gi_base "$d"
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "" "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:25:00Z
  gi_refused "$d" "AC1 missing line (later plan)" "Prod effect" || return 1
  rm -rf "$d"
}

test_gi_ac1_neg_missing_prod_effect_in_go_time_plan() {
  local d
  d=$(mktemp -d)
  printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
  gi_ready "$d" 2026-10-16T10:00:00Z "$(gi_plan "" "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:05:00Z
  gi_go "$d" 2026-10-16T10:10:00Z
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "$GI_P1" "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:25:00Z
  gi_refused "$d" "AC1 missing line (go-time plan)" "Prod effect" || return 1
  rm -rf "$d"
}

test_gi_ac1_neg_chain_is_compared_pairwise() {
  local d
  # revision 2 changes the target, revision 3 changes it back: still refused (rev 2 broke the chain)
  d=$(mktemp -d); gi_base "$d"
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan 'target=other project; env=prod; data=DNS A record for example.test; irreversible=no' "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:25:00Z
  gi_ready "$d" 2026-10-16T10:30:00Z "$(gi_plan "$GI_P1" "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:35:00Z
  gi_refused "$d" "AC1 changed then reverted" "other project" || return 1
  rm -rf "$d"
  # revision 2 unchanged, revision 3 changes (vs revision 2)
  d=$(mktemp -d); gi_base "$d"
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "$GI_P1" "" b 'flip back')"
  gi_pass "$d" 2026-10-16T10:25:00Z
  gi_ready "$d" 2026-10-16T10:30:00Z "$(gi_plan "$GI_P1" "$GI_EXTRA_PROD" b 'flip back')"
  gi_pass "$d" 2026-10-16T10:35:00Z
  gi_refused "$d" "AC1 third revision adds prod step" "new webhook" || return 1
  rm -rf "$d"
}

test_gi_ac1_two_unchanged_revisions_still_inherit() {
  local d r
  d=$(mktemp -d); gi_base "$d"
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "$GI_P1" "" b 'x')"
  gi_pass "$d" 2026-10-16T10:25:00Z
  gi_ready "$d" 2026-10-16T10:30:00Z "$(gi_plan "$GI_P1" "" a 'y')"
  gi_pass "$d" 2026-10-16T10:35:00Z
  r=$(gi_run "$d")
  assert_eq "$(gi_rc "$r")" "0" "AC1: chain of unchanged revisions inherits" || return 1
  rm -rf "$d"
}

test_gi_failed_read_is_not_an_inherited_go() {
  local d r
  d=$(mktemp -d); gi_base "$d"
  r=$(gi_run "$d" fail)
  assert_eq "$(gi_rc "$r")" "2" "failed read: rc 2" || return 1
  assert_not_contains "$(gi_out "$r")" "go inherited" "failed read: never inherited" || return 1
  rm -rf "$d"
}

# ---------------------------------------------------------------------------------------- AC2 / AC5 log

test_gi_ac2_inherit_writes_validate_line() {
  local d r l
  d=$(mktemp -d); gi_base "$d"
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "$GI_P1" "" b 'x')"
  gi_pass "$d" 2026-10-16T10:25:00Z
  r=$(gi_run "$d"); l=$(gi_log "$d")
  assert_contains "$l" "validate" "AC2: validate line" || return 1
  assert_contains "$l" "go inherited: prod effect unchanged" "AC2: reason" || return 1
  assert_eq "$(printf '%s\n' "$l" | sed '/^$/d' | wc -l | tr -d ' ')" "1" "AC2: exactly one line" || return 1
  rm -rf "$d"
}

test_gi_ac5_refusal_writes_validate_line_with_repo_issue_reason_and_no_bodies() {
  local d r l
  d=$(mktemp -d); gi_base "$d"
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan 'target=benjis-prod-v2; env=prod; data=x; irreversible=no' "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:25:00Z
  r=$(gi_run "$d"); l=$(gi_log "$d")
  assert_contains "$l" "validate" "AC5: validate line on refusal" || return 1
  assert_contains "$l" "o/r" "AC5: repo" || return 1
  assert_contains "$l" "9" "AC5: issue" || return 1
  assert_contains "$l" "fresh go required:" "AC5: reason" || return 1
  assert_not_contains "$l" "SECRETSENTINEL" "AC5: no plan body / secrets" || return 1
  assert_not_contains "$l" "Authorization" "AC5: no command text" || return 1
  assert_eq "$(printf '%s\n' "$l" | sed '/^$/d' | wc -l | tr -d ' ')" "1" "AC5: one line" || return 1
  rm -rf "$d"
}

# ---------------------------------------------------------------------------------------- AC3 text

test_gi_ac3_planner_template_and_rule_require_prod_effect() {
  local blk
  blk=$(awk '/^```/ { if (inb) { if (index(b, "PLAN READY")) { printf "%s", b; exit } inb = 0; b = "" } else { inb = 1; b = "" } next } inb { b = b $0 "\n" }' "$PL_GI")
  assert_contains "$blk" "Prod effect:" "AC3: planner template step block carries a Prod effect line" || return 1
  grep -qiE 'Prod effect:.*(target|environment|data|irreversib)' "$PL_GI" || { fail "AC3: planner rule must spell out target, environment, data touched, irreversibility"; return 1; }
  grep -qiE 'every .?\[prod\]|each .?\[prod\]|per prod step|prod step' "$PL_GI" || { fail "AC3: planner says it applies to each prod step"; return 1; }
}

test_gi_ac3_reviewer_checks_prod_effect() {
  local n
  n=$(grep -c 'Prod effect' "$RV_GI")
  [ "$n" -ge 1 ] || { fail "AC3: infra-reviewer.md must check Prod effect lines"; return 1; }
  grep -qiE 'prod effect.*(missing|every|each|present|per)|(every|each|per).*prod effect' "$RV_GI" || { fail "AC3: reviewer checklist item requires a Prod effect on every prod step"; return 1; }
}

test_gi_operator_documents_inherited_go_and_awaiting_go_listing() {
  grep -qF 'go_inherit' "$OP_GI" || { fail "operator names go_inherit"; return 1; }
  grep -qiE 'inherit' "$OP_GI" || { fail "operator documents inheritance"; return 1; }
  grep -qiE 'AWAITING GO.*(changed|prod effect)|(changed|prod effect).*AWAITING GO' "$OP_GI" || { fail "operator lists changed prod effects in AWAITING GO"; return 1; }
  grep -qF 'go inherited: prod effect unchanged' "$OP_GI" || { fail "operator spells the validate reason"; return 1; }
  grep -qF 'fresh go required:' "$OP_GI" || { fail "operator spells the refusal reason"; return 1; }
}

# ---------------------------------------------------------------------------------------- AC4 untouched

test_gi_ac4_orchestrator_date_rule_gates_untouched() {
  local base cur_f base_f k
  base=$(git -C "$ROOT_GI" merge-base HEAD origin/main 2>/dev/null) || { fail "AC4: no merge-base with origin/main"; return 1; }
  # the jp_go helper and every mockup / needs-JP / delegated-decision line stay byte-identical
  cur_f=$(awk '/^jp_go\(\)/{on=1} on{print} on&&/^}$/{exit}' "$ORCH_GI")
  base_f=$(git -C "$ROOT_GI" show "$base:agents/orchestrator.md" | awk '/^jp_go\(\)/{on=1} on{print} on&&/^}$/{exit}')
  assert_ne "$cur_f" "" "AC4: jp_go found" || return 1
  assert_eq "$cur_f" "$base_f" "AC4: jp_go unchanged" || return 1
  for k in 'MOCKUPS APPROVED' 'needs_jp' 'delegated-decision'; do
    assert_eq "$(grep -F "$k" "$ORCH_GI")" "$(git -C "$ROOT_GI" show "$base:agents/orchestrator.md" | grep -F "$k")" "AC4: lines containing [$k] unchanged" || return 1
  done
}

test_gi_ac4_orchestrator_states_operator_may_proceed_on_inherited_go() {
  grep -qiE 'inherited go|go inherited|inherit' "$ORCH_GI" || { fail "orchestrator.md must state the operator may proceed on an inherited go"; return 1; }
}

run_test test_gi_ac1_positive_unchanged_prod_effect_inherits
run_test test_gi_ac1_go_after_latest_pass_needs_no_inheritance_even_for_legacy_plan
run_test test_gi_ac1_neg_changed_target_database
run_test test_gi_ac1_neg_added_prod_step
run_test test_gi_ac1_neg_new_step_deleting_data
run_test test_gi_ac1_neg_plan_edited_by_non_agent
run_test test_gi_ac1_neg_go_from_non_author
run_test test_gi_ac1_neg_go_not_exactly_go
run_test test_gi_ac1_neg_missing_prod_effect_in_later_plan
run_test test_gi_ac1_neg_missing_prod_effect_in_go_time_plan
run_test test_gi_ac1_neg_chain_is_compared_pairwise
run_test test_gi_ac1_two_unchanged_revisions_still_inherit
run_test test_gi_failed_read_is_not_an_inherited_go
run_test test_gi_ac2_inherit_writes_validate_line
run_test test_gi_ac5_refusal_writes_validate_line_with_repo_issue_reason_and_no_bodies
run_test test_gi_ac3_planner_template_and_rule_require_prod_effect
run_test test_gi_ac3_reviewer_checks_prod_effect
run_test test_gi_operator_documents_inherited_go_and_awaiting_go_listing
run_test test_gi_ac4_orchestrator_date_rule_gates_untouched
run_test test_gi_ac4_orchestrator_states_operator_may_proceed_on_inherited_go
