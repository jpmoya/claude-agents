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
#   Additions (test-review round 1, ticket-silent details pinned here):
#     * log line format: `[<ts>] validate repo=<REPO> issue=<N> <reason>`; rc 2 also writes ONE line, reason `failed read`.
#     * no valid go (non-author / not exactly go / dated before every PLAN PASS) => reason has `no valid go`.
#     * marker author (PM clarification (a)): the first line of the PLAN READY / PLAN PASS comment must be
#       `**[infra-planner]|[solutions-architect] PLAN READY**` / `**[infra-reviewer]|[solutions-architect] PLAN PASS**`;
#       any other author (e.g. [jp], [fullstack-developer]) => reason has `not authored by an agent`.
#     * edited plan comment => reason has `edited`.
#     * JP-only list (d): ANY step, whatever its environment, touching spending money / third-party system of
#       record / deleting data / external comms / secret-store location or access carries a line
#       `JP-only: <category>`; a `JP-only:` line in a later plan that the earlier plan lacks => reason has `JP-only`.
#       (the planner emits these lines; identical lines in both plans never invalidate a go)
#     * gh stub shape is part of the contract: `gh api repos/{owner}/{repo}/issues/<N>` and `.../comments...`.
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
    inb && !on && ($0 ~ /^[[:space:]]*go_inherit[[:space:]]*\(\)/ || $0 ~ /^[[:space:]]*function[[:space:]]+go_inherit/) { on = 1; ind = $0; sub(/[^[:space:]].*$/, "", ind) }
    inb && on { print; if ($0 == ind "}") exit }
  ' "$OP_GI"
}

GI_DIRS=""
gi_mk() { local d; d=$(mktemp -d); GI_DIRS="$GI_DIRS $d"; printf '%s' "$d"; }
gi_cleanup() { [ -z "$GI_DIRS" ] || rm -rf $GI_DIRS; GI_DIRS=""; }

# gi_plan <prod1-effect|""> <extra-steps> <staging-variant: a|b> <rollback-note> — a PLAN READY body
gi_plan() {
  local p1=$1 extra=$2 variant=$3 rb=$4 s_a s_b
  s_a=$'### Step 1 — Lower TTL  [staging]\nDepends on: none\nCommand:\n```bash\nvercel dns add example.test @ A 1.2.3.4 --scope benjisops\n```\nRollback: '"$rb"
  s_b=$'### Step 2 — Add alias  [staging]\nDepends on: none\nCommand:\n```bash\nvercel alias set x y --scope benjisops\n```\nRollback: remove alias'
  printf '%s\n' '**[infra-planner] PLAN READY**' 'Goal: move host' 'Environments touched: both' '' '## Steps'
  if [ "$variant" = a ]; then printf '%s\n\n%s\n\n' "$s_a" "$s_b"; else printf '%s\n\n%s\n\n' "$s_b" "$s_a"; fi
  printf '%s\n' '### Step 3 — Flip prod DNS  [prod]' 'Depends on: Step 1' 'Command:' '```bash' 'curl -H "Authorization: Bearer SECRETSENTINEL" https://api.example.test/flip' '```'  # gitleaks:allow
  [ -n "$p1" ] && printf 'Prod effect: %s\n' "$p1"
  printf '%s\n' 'Rollback: flip back' ''
  [ -n "$extra" ] && printf '%s\n' "$extra"
  return 0
}

GI_EXTRA_PROD=$'### Step 4 — Add prod webhook  [prod]\nDepends on: Step 3\nCommand:\n```bash\ncurl -X POST https://api.example.test/hooks\n```\nProd effect: target=hooks api; env=prod; data=new webhook; irreversible=no\nRollback: delete hook\n'
GI_EXTRA_STAGING_SPEND=$'### Step 4 — Buy capacity  [staging]\nDepends on: none\nCommand:\n```bash\nvercel teams upgrade --scope benjisops\n```\nJP-only: spending money\nRollback: downgrade\n'
GI_EXTRA_STAGING_PLAIN=$'### Step 4 — Warm cache  [staging]\nDepends on: none\nCommand:\n```bash\nvercel alias ls --scope benjisops\n```\nRollback: none needed\n'
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

# gi_as <marker-author> <body> — swap the author in the body's first-line marker ([infra-planner] -> [x])
gi_as() { printf '%s\n' "$2" | sed "1s/\\[infra-planner\\]/[$1]/"; }

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
    . "$ROOT_GI/hooks/pipeline-markers.sh"   # jp_approval_re, the shared approval-word set (#310)
    eval "$code"
    out=$(go_inherit 9 2>/dev/null); rc=$?
    printf '%s\nRC=%s\n' "$out" "$rc"
  )
}
gi_out() { printf '%s\n' "$1" | sed '$d'; }
gi_rc() { printf '%s\n' "$1" | tail -1 | sed 's/^RC=//'; }
gi_log() { cat "$1/slog" 2>/dev/null; }

# gi_refused <dir> <label> <expect-in-reason> — shared negative assertion (rc 1, fresh go, cause named)
gi_refused() {
  local d=$1 label=$2 want=$3 r
  r=$(gi_run "$d")
  assert_eq "$(gi_rc "$r")" "1" "$label: rc 1" || return 1
  assert_contains "$(gi_out "$r")" "fresh go required:" "$label: reason prefix" || return 1
  assert_contains "$(gi_out "$r")" "$want" "$label: names the cause" || return 1
  assert_not_contains "$(gi_out "$r")" "go inherited" "$label: not inherited" || return 1
}
# gi_inherits <dir> <label> — shared positive assertion
gi_inherits() {
  local r; r=$(gi_run "$1")
  assert_eq "$(gi_rc "$r")" "0" "$2: rc 0" || return 1
  assert_eq "$(gi_out "$r")" "go inherited: prod effect unchanged" "$2: reason line" || return 1
}
# gi_rev <dir> <created-ready> <created-pass> <plan-body> [ready-updated] — one agent plan revision (READY + PASS)
gi_rev() { gi_ready "$1" "$2" "$4" "${5:-$2}"; gi_pass "$1" "$3"; }

# ---------------------------------------------------------------------------------------- AC1 positive

test_gi_ac1_positive_whitespace_only_prod_effect_diff_inherits() {
  local d p1b
  d=$(gi_mk); gi_base "$d"
  p1b="target=vercel   project benjis-prod;  env=prod; data=DNS A record for example.test;   irreversible=no "
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$p1b" "" a 'flip back')"
  gi_inherits "$d" "AC1 whitespace-only"
}

test_gi_ac1_positive_reordered_staging_steps_inherit() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "" b 'flip back')"
  gi_inherits "$d" "AC1 reorder"
}

test_gi_ac1_positive_reworded_rollback_inherits() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "" a 'a reworded rollback note')"
  gi_inherits "$d" "AC1 reworded rollback"
}

test_gi_ac1_positive_added_plain_staging_step_inherits() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "$GI_EXTRA_STAGING_PLAIN" a 'flip back')"
  gi_inherits "$d" "AC1 plain staging step"
}

test_gi_ac1_positive_solutions_architect_revision_inherits() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_as solutions-architect "$(gi_plan "$GI_P1" "" b 'flip back')")"
  gi_inherits "$d" "AC1 [solutions-architect] revision"
}

test_gi_ac1_positive_unchanged_jp_only_line_inherits() {
  local d
  d=$(gi_mk)
  printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
  gi_rev "$d" 2026-10-16T10:00:00Z 2026-10-16T10:05:00Z "$(gi_plan "$GI_P1" "$GI_EXTRA_STAGING_SPEND" a 'flip back')"
  gi_go "$d" 2026-10-16T10:10:00Z
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "$GI_EXTRA_STAGING_SPEND" b 'flip back')"
  gi_inherits "$d" "AC1 same JP-only line in both plans"
}

test_gi_ac1_two_unchanged_revisions_still_inherit() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "" b 'x')"
  gi_rev "$d" 2026-10-16T10:30:00Z 2026-10-16T10:35:00Z "$(gi_plan "$GI_P1" "" a 'y')"
  gi_inherits "$d" "AC1 two unchanged revisions"
}

test_gi_ac1_go_after_latest_pass_needs_no_inheritance_even_for_legacy_plan() {
  local d r
  d=$(gi_mk)
  printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
  gi_ready "$d" 2026-10-16T10:00:00Z "$(gi_plan "" "" a 'flip back')"   # legacy plan: no Prod effect line
  gi_pass "$d" 2026-10-16T10:05:00Z
  gi_go "$d" 2026-10-16T10:10:00Z
  r=$(gi_run "$d")
  assert_eq "$(gi_rc "$r")" "0" "AC1: legacy plan, go after latest PASS still valid" || return 1
  assert_not_contains "$(gi_out "$r")" "fresh go required" "AC1: not refused" || return 1
}

test_gi_ac1_valid_go_after_an_earlier_invalid_go_inherits() {
  local d
  d=$(gi_mk)
  printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
  gi_ready "$d" 2026-10-16T10:00:00Z "$(gi_plan "$GI_P1" "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:05:00Z
  gi_go "$d" 2026-10-16T10:07:00Z jpmoya "go ahead"
  gi_go "$d" 2026-10-16T10:10:00Z
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "" b 'flip back')"
  gi_inherits "$d" "AC1 invalid go then valid go"
}

# ---------------------------------------------------------------------------------------- AC1 negative

test_gi_ac1_neg_changed_target_database() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan 'target=vercel project benjis-prod-v2; env=prod; data=DNS A record for example.test; irreversible=no' "" a 'flip back')"
  gi_refused "$d" "AC1 changed target" "benjis-prod-v2"
}

test_gi_ac1_neg_added_prod_step() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "$GI_EXTRA_PROD" a 'flip back')"
  gi_refused "$d" "AC1 added prod step" "new webhook"
}

test_gi_ac1_neg_added_prod_step_deleting_data() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "$GI_EXTRA_DELETE" a 'flip back')"
  gi_refused "$d" "AC1 prod step deleting data" "DELETE quotes_old rows"
}

# (d) alone: the new step is [staging], so (b)/(c) cannot catch it — only its JP-only line can
test_gi_ac1_neg_new_staging_step_touching_jp_only_list() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "$GI_EXTRA_STAGING_SPEND" a 'flip back')"
  gi_refused "$d" "AC1(d) staging step with JP-only line" "JP-only" || return 1
  assert_contains "$(gi_out "$(gi_run "$d")")" "spending money" "AC1(d): names the JP-only category" || return 1
}

test_gi_ac1_neg_plan_comment_edited_after_posting() {
  local d
  d=$(gi_mk); gi_base "$d"
  # identical Prod effect, but the comment was edited 10 minutes after its created_at
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "" b 'flip back')" 2026-10-16T10:30:00Z
  gi_refused "$d" "AC1(a) edited plan" "edited"
}

test_gi_ac1_neg_plan_ready_authored_by_jp() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_as jp "$(gi_plan "$GI_P1" "" b 'flip back')")"
  gi_refused "$d" "AC1(a) [jp] PLAN READY" "not authored by an agent"
}

test_gi_ac1_neg_plan_ready_authored_by_fullstack_developer() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_as fullstack-developer "$(gi_plan "$GI_P1" "" b 'flip back')")"
  gi_refused "$d" "AC1(a) [fullstack-developer] PLAN READY" "not authored by an agent"
}

test_gi_ac1_neg_plan_pass_authored_by_jp() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_ready "$d" 2026-10-16T10:20:00Z "$(gi_plan "$GI_P1" "" b 'flip back')"
  gi_add "$d" jpmoya 2026-10-16T10:25:00Z 2026-10-16T10:25:00Z $'**[jp] PLAN PASS**\nlooks fine'
  gi_refused "$d" "AC1(a) [jp] PLAN PASS" "not authored by an agent"
}

test_gi_ac1_neg_go_from_non_author() {
  local d
  d=$(gi_mk)
  printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
  gi_ready "$d" 2026-10-16T10:00:00Z "$(gi_plan "$GI_P1" "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:05:00Z
  gi_go "$d" 2026-10-16T10:10:00Z someone-else
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "" b 'flip back')"
  gi_refused "$d" "AC1 non-author go" "no valid go"
}

# parameterised: one test per non-go body
gi_nongo_case() {
  local d
  d=$(gi_mk)
  printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
  gi_ready "$d" 2026-10-16T10:00:00Z "$(gi_plan "$GI_P1" "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:05:00Z
  gi_go "$d" 2026-10-16T10:10:00Z jpmoya "$1"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "" b 'flip back')"
  gi_refused "$d" "AC1 go body [$1]" "no valid go"
}
test_gi_ac1_neg_go_body_go_ahead() { gi_nongo_case 'go ahead'; }
test_gi_ac1_neg_go_body_going_to_review() { gi_nongo_case 'going to review'; }
test_gi_ac1_neg_go_body_not_go() { gi_nongo_case 'not go'; }

test_gi_ac1_neg_go_dated_before_every_plan_pass() {
  local d
  d=$(gi_mk)
  printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
  gi_ready "$d" 2026-10-16T10:00:00Z "$(gi_plan "$GI_P1" "" a 'flip back')"
  gi_go "$d" 2026-10-16T10:02:00Z
  gi_pass "$d" 2026-10-16T10:05:00Z
  gi_refused "$d" "AC1 go before first PASS" "no valid go"
}

test_gi_ac1_neg_missing_prod_effect_in_later_plan() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "" "" a 'flip back')"
  gi_refused "$d" "AC1 missing line (later plan)" "Prod effect"
}

test_gi_ac1_neg_missing_prod_effect_in_go_time_plan() {
  local d
  d=$(gi_mk)
  printf '{"user":{"login":"jpmoya"}}\n' > "$d/issue.json"
  gi_ready "$d" 2026-10-16T10:00:00Z "$(gi_plan "" "" a 'flip back')"
  gi_pass "$d" 2026-10-16T10:05:00Z
  gi_go "$d" 2026-10-16T10:10:00Z
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "" a 'flip back')"
  gi_refused "$d" "AC1 missing line (go-time plan)" "Prod effect"
}

# revision 2 changes the target, revision 3 changes it back: still refused (rev 2 broke the chain)
test_gi_ac1_neg_chain_change_then_revert_is_refused() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan 'target=other project; env=prod; data=DNS A record for example.test; irreversible=no' "" a 'flip back')"
  gi_rev "$d" 2026-10-16T10:30:00Z 2026-10-16T10:35:00Z "$(gi_plan "$GI_P1" "" a 'flip back')"
  gi_refused "$d" "AC1 changed then reverted" "other project"
}

# revision 2 unchanged, revision 3 changes (vs revision 2)
test_gi_ac1_neg_chain_third_revision_adds_prod_step() {
  local d
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "" b 'flip back')"
  gi_rev "$d" 2026-10-16T10:30:00Z 2026-10-16T10:35:00Z "$(gi_plan "$GI_P1" "$GI_EXTRA_PROD" b 'flip back')"
  gi_refused "$d" "AC1 third revision adds prod step" "new webhook"
}

# ---------------------------------------------------------------------------------------- AC5 failed read

test_gi_failed_read_is_not_an_inherited_go() {
  local d r
  d=$(gi_mk); gi_base "$d"
  r=$(gi_run "$d" fail)
  assert_eq "$(gi_rc "$r")" "2" "failed read: rc 2" || return 1
  assert_not_contains "$(gi_out "$r")" "go inherited" "failed read: never inherited" || return 1
}

test_gi_ac5_failed_read_writes_one_validate_line_with_repo_issue_reason() {
  local d l
  d=$(gi_mk); gi_base "$d"
  gi_run "$d" fail >/dev/null; l=$(gi_log "$d")
  assert_contains "$l" "validate" "AC5 rc 2: validate line" || return 1
  assert_contains "$l" "repo=o/r" "AC5 rc 2: repo" || return 1
  assert_contains "$l" "issue=9" "AC5 rc 2: issue" || return 1
  assert_contains "$l" "failed read" "AC5 rc 2: reason" || return 1
  assert_eq "$(printf '%s\n' "$l" | sed '/^$/d' | wc -l | tr -d ' ')" "1" "AC5 rc 2: one line" || return 1
}

# ---------------------------------------------------------------------------------------- AC2 / AC5 log

test_gi_ac2_inherit_writes_validate_line() {
  local d l
  d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan "$GI_P1" "" b 'x')"
  gi_run "$d" >/dev/null; l=$(gi_log "$d")
  assert_contains "$l" "validate" "AC2: validate line" || return 1
  assert_contains "$l" "go inherited: prod effect unchanged" "AC2: reason" || return 1
  assert_eq "$(printf '%s\n' "$l" | sed '/^$/d' | wc -l | tr -d ' ')" "1" "AC2: exactly one line" || return 1
}

gi_refusal_log() {   # changed-target refusal; prints the log
  local d; d=$(gi_mk); gi_base "$d"
  gi_rev "$d" 2026-10-16T10:20:00Z 2026-10-16T10:25:00Z "$(gi_plan 'target=benjis-prod-v2; env=prod; data=x; irreversible=no' "" a 'flip back')"
  gi_run "$d" >/dev/null; gi_log "$d"
}

test_gi_ac5_refusal_writes_validate_line_with_repo_issue_and_reason() {
  local l; l=$(gi_refusal_log)
  assert_contains "$l" "validate" "AC5: validate line on refusal" || return 1
  assert_contains "$l" "repo=o/r" "AC5: repo" || return 1
  assert_contains "$l" "issue=9" "AC5: issue" || return 1
  assert_contains "$l" "fresh go required:" "AC5: reason" || return 1
  assert_eq "$(printf '%s\n' "$l" | sed '/^$/d' | wc -l | tr -d ' ')" "1" "AC5: one line" || return 1
}

test_gi_ac5_refusal_log_has_no_plan_bodies_or_commands() {
  local l; l=$(gi_refusal_log)
  assert_ne "$l" "" "AC5: a line was written" || return 1
  assert_not_contains "$l" "SECRETSENTINEL" "AC5: no secrets" || return 1
  assert_not_contains "$l" "Authorization" "AC5: no command text" || return 1
  assert_not_contains "$l" "Depends on" "AC5: no plan body" || return 1
}

# ---------------------------------------------------------------------------------------- AC3 text

test_gi_ac3_planner_template_carries_prod_effect_line() {
  local blk
  blk=$(awk '/^```/ { if (inb) { if (index(b, "PLAN READY")) { printf "%s", b; exit } inb = 0; b = "" } else { inb = 1; b = "" } next } inb { b = b $0 "\n" }' "$PL_GI")
  assert_contains "$blk" "Prod effect:" "AC3: planner template step block carries a Prod effect line" || return 1
}

test_gi_ac3_planner_rule_requires_prod_effect_on_every_prod_step() {
  grep -qiE 'Prod effect.*(every|each|per).*\[prod\]|(every|each|per).*\[prod\].*Prod effect' "$PL_GI" || { fail "AC3: planner rule: Prod effect on every [prod] step"; return 1; }
  grep -qiE 'Prod effect:.*(target|environment|env)' "$PL_GI" && grep -qiE 'Prod effect.*(data touched|data)' "$PL_GI" && grep -qiE 'Prod effect.*irreversib' "$PL_GI" || { fail "AC3: planner rule spells out target, environment, data touched, irreversibility"; return 1; }
}

test_gi_ac3_planner_emits_jp_only_lines() {
  grep -qF 'JP-only:' "$PL_GI" || { fail "AC3/(d): planner must emit a 'JP-only:' line on any step touching the JP-only list"; return 1; }
}

test_gi_ac3_reviewer_checks_prod_effect_on_every_prod_step() {
  grep -qiE 'prod effect.*(missing|every|each|present|per)|(every|each|per).*prod effect' "$RV_GI" || { fail "AC3: reviewer checklist item requires a Prod effect on every prod step"; return 1; }
}

test_gi_operator_documents_inherited_go_and_awaiting_go_listing() {
  grep -qF 'go_inherit' "$OP_GI" || { fail "operator names go_inherit"; return 1; }
  grep -qiE 'AWAITING GO.*(changed|prod effect)|(changed|prod effect).*AWAITING GO' "$OP_GI" || { fail "operator lists changed prod effects in AWAITING GO"; return 1; }
  grep -qF 'go inherited: prod effect unchanged' "$OP_GI" || { fail "operator spells the validate reason"; return 1; }
  grep -qF 'fresh go required:' "$OP_GI" || { fail "operator spells the refusal reason"; return 1; }
}

# ---------------------------------------------------------------------------------------- AC4 untouched
# Baseline pinned to the content at merge-base 4179fc6 (inline golden / content hash), not to a moving ref.

GI_JP_GO_GOLDEN='jp_go() {  # jp_go <N> <blocked_created_at>: URL + timestamp of each JP go after that BLOCKED/AWAITING GO; non-zero + no output on a failed read
  local a c
  a=$(gh api "repos/{owner}/{repo}/issues/$1" --jq '"'"'.user.login'"'"') && [ -n "$a" ] || return 1
  c=$(gh api "repos/{owner}/{repo}/issues/$1/comments?per_page=100" --paginate \
    --jq ".[] | select(.user.login == \"$a\" and .created_at > \"$2\" and ((.body | split(\"\n\")[0] | sub(\"[ \\t\\r]+$\"; \"\")) as \$l | [\"go\", \"GO\", \"**[jp] GO**\"] | index(\$l))) | .html_url + \" \" + .created_at") || return 1
  printf '"'"'%s\n'"'"' "$c" | sed '"'"'/^$/d'"'"'
}'

gi_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'; }

test_gi_ac4_orchestrator_jp_go_untouched() {
  # #322: the 4179fc6 golden is retired — #310 moved jp_go onto the shared approval-word set; it must use it and keep its read-failure contract.
  local cur
  cur=$(awk '/^jp_go\(\)/{on=1} on{print} on&&/^}$/{exit}' "$ORCH_GI")
  assert_contains "$cur" 'jp_approval_re' "AC4: jp_go uses the shared approval-word set" || return 1
  assert_contains "$cur" '|| return 1' "AC4: jp_go still fails closed on a failed read" || return 1
}

test_gi_ac4_orchestrator_mockups_approved_lines_untouched() {
  assert_eq "$(grep -F 'MOCKUPS APPROVED' "$ORCH_GI" | gi_sha)" "d51b67799f66c9541d52667c24f3c761cab348a1ffb0934626a4f4ee2b8daedd" "AC4: MOCKUPS APPROVED lines"
}

test_gi_ac4_orchestrator_needs_jp_lines_untouched() {
  # Re-pinned for the auto-retry-NOTE reader fix: only the auto-retry row changed (how its NOTE is matched); its
  # "Never applies to needs_jp …" clause and every other needs_jp line are byte-identical.
  # Re-pinned for #523 (position-independent Resolves:): the only change is the code-track DECISION resume row's
  # "whose line 2 is `Resolves: …`" → "that carries exactly one unquoted `Resolves: …` line (any position after line 1; …)".
  assert_eq "$(grep -F 'needs_jp' "$ORCH_GI" | gi_sha)" "04c523918204c3a181239e2ae2a97d72bd8956eb6e9daddbc615fdaf1c54bd06" "AC4: needs_jp lines"
}

test_gi_ac4_orchestrator_delegated_decision_lines_untouched() {
  # Re-pinned for #523: same single-row wording change as the needs_jp pin above; nothing else in these lines moved.
  assert_eq "$(grep -F 'delegated-decision' "$ORCH_GI" | gi_sha)" "7ba99345dbd5ed3888ff8d4716cebe761b5eaa02e1094d4b23220fbc5e05e58e" "AC4: delegated-decision lines"
}

test_gi_ac4_orchestrator_states_operator_may_proceed_on_inherited_go() {
  grep -iE 'operator' "$ORCH_GI" | grep -qiE 'inherited go|go_inherit' || { fail "orchestrator.md must state, in a line about the operator, that it may proceed on an inherited go"; return 1; }
}

run_test test_gi_ac1_positive_whitespace_only_prod_effect_diff_inherits
run_test test_gi_ac1_positive_reordered_staging_steps_inherit
run_test test_gi_ac1_positive_reworded_rollback_inherits
run_test test_gi_ac1_positive_added_plain_staging_step_inherits
run_test test_gi_ac1_positive_solutions_architect_revision_inherits
run_test test_gi_ac1_positive_unchanged_jp_only_line_inherits
run_test test_gi_ac1_two_unchanged_revisions_still_inherit
run_test test_gi_ac1_go_after_latest_pass_needs_no_inheritance_even_for_legacy_plan
run_test test_gi_ac1_valid_go_after_an_earlier_invalid_go_inherits
run_test test_gi_ac1_neg_changed_target_database
run_test test_gi_ac1_neg_added_prod_step
run_test test_gi_ac1_neg_added_prod_step_deleting_data
run_test test_gi_ac1_neg_new_staging_step_touching_jp_only_list
run_test test_gi_ac1_neg_plan_comment_edited_after_posting
run_test test_gi_ac1_neg_plan_ready_authored_by_jp
run_test test_gi_ac1_neg_plan_ready_authored_by_fullstack_developer
run_test test_gi_ac1_neg_plan_pass_authored_by_jp
run_test test_gi_ac1_neg_go_from_non_author
run_test test_gi_ac1_neg_go_body_go_ahead
run_test test_gi_ac1_neg_go_body_going_to_review
run_test test_gi_ac1_neg_go_body_not_go
run_test test_gi_ac1_neg_go_dated_before_every_plan_pass
run_test test_gi_ac1_neg_missing_prod_effect_in_later_plan
run_test test_gi_ac1_neg_missing_prod_effect_in_go_time_plan
run_test test_gi_ac1_neg_chain_change_then_revert_is_refused
run_test test_gi_ac1_neg_chain_third_revision_adds_prod_step
run_test test_gi_failed_read_is_not_an_inherited_go
run_test test_gi_ac5_failed_read_writes_one_validate_line_with_repo_issue_reason
run_test test_gi_ac2_inherit_writes_validate_line
run_test test_gi_ac5_refusal_writes_validate_line_with_repo_issue_and_reason
run_test test_gi_ac5_refusal_log_has_no_plan_bodies_or_commands
run_test test_gi_ac3_planner_template_carries_prod_effect_line
run_test test_gi_ac3_planner_rule_requires_prod_effect_on_every_prod_step
run_test test_gi_ac3_planner_emits_jp_only_lines
run_test test_gi_ac3_reviewer_checks_prod_effect_on_every_prod_step
run_test test_gi_operator_documents_inherited_go_and_awaiting_go_listing
run_test test_gi_ac4_orchestrator_jp_go_untouched
run_test test_gi_ac4_orchestrator_mockups_approved_lines_untouched
run_test test_gi_ac4_orchestrator_needs_jp_lines_untouched
run_test test_gi_ac4_orchestrator_delegated_decision_lines_untouched
run_test test_gi_ac4_orchestrator_states_operator_may_proceed_on_inherited_go
gi_cleanup
