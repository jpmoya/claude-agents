#!/bin/bash
# Issue #89 — a staging-only infra-track planner/operator BLOCKED resumes on a delegated decision.
# Standalone (not picked up by tests/run-tests.sh). Functions are extracted from supervisor.sh (sourcing it would run a
# tick). `gh` is a PATH shim serving canned JSON. Placeholder repo names only.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUP="$HERE/../supervisor.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export PIPE="$TMP/pipe"; mkdir -p "$PIPE" "$TMP/bin"
export GRACE_PERIOD_SECS=0 CASE_JSON="$TMP/case.json"
slog() { :; }

# gh shim: `repo view` -> acme/widgets; `issue view` / `api` serve $CASE_JSON in either shape, honouring --jq/-q.
cat > "$TMP/bin/gh" <<'SH'
#!/bin/bash
args=("$@"); jq_expr=""; for ((i=0;i<${#args[@]};i++)); do case "${args[i]}" in --jq|-q) jq_expr=${args[i+1]};; esac; done
case "$1 $2" in
  "repo view") echo "acme/widgets"; exit 0;;
  "issue view") src=$(jq -c '.' "$CASE_JSON");;
  *) case "$1" in api)
       case "$*" in *comments*) src=$(jq -c '.comments | map(. + {html_url: .url, created_at: .createdAt})' "$CASE_JSON");;
                    *) src=$(jq -c '. + {html_url: "https://x/issues/1"}' "$CASE_JSON");; esac;;
     *) exit 0;; esac;;
esac
if [ -n "$jq_expr" ]; then printf '%s' "$src" | jq -r "$jq_expr"; else printf '%s' "$src"; fi
SH
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

for fn in to_epoch terminal_kind infra_staging_only; do
  eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$SUP")"
done
source "$HERE/../../../hooks/pipeline-markers.sh"; source "$HERE/../pipeline-lib.sh"

PASS=0; FAIL=0; FAILED=""
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); FAILED="$FAILED\n  $1"; echo "FAIL: $1 — $2"; }
U=https://github.com/acme/widgets/issues/7#issuecomment-
BODY_OK=$'Why: x\nScope: staging-only\nMore'
PLAN_OK=$'**[infra-planner] PLAN READY**\n### Step 1\nTarget environment: staging\nrun it'

# c <n> <ts> <body> → a comment JSON object (url ends with n)
c() { jq -n --arg u "$U$1" --arg t "$2" --arg b "$3" '{url:$u,createdAt:$t,body:$b}'; }
# build <issue-body> <comment>... → writes $CASE_JSON
build() { local body=$1; shift; printf '%s\n' "$@" | jq -s --arg b "$body" '{body:$b,comments:.}' > "$CASE_JSON"; }

# scenario: kind(planner|operator) → sets BLK marker + comment 3 body
DEC=$'**[project-manager] DECISION**\nResolves: '"${U}3"$'\nproceed.'
run_kind() { # <blocked marker> <decision-line1>
  terminal_kind "$1" 7 "$2"; }
check_kind() { # <name> <expected> <marker> <decision-line1>
  local got; got=$(run_kind "$3" "$4" 2>/dev/null)
  [ "$got" = "$2" ] && ok || bad "$1" "expected [$2] got [$got]"; }
check_helper() { # <name> <expected-rc>
  infra_staging_only acme/widgets 7 "${U}3" >/dev/null 2>&1; local rc=$?
  [ "$rc" = "$2" ] && ok || bad "$1 (helper)" "expected rc $2 got $rc"; }
both() { # <name> <expect-resume yes|no> <marker> — asserts terminal_kind and the helper
  if [ "$2" = yes ]; then check_kind "$1" "" "$3" '**[project-manager] DECISION**'; check_helper "$1" 0
  else check_kind "$1" gate "$3" '**[project-manager] DECISION**'; check_helper "$1" 1; fi; }

PL='**[infra-planner] BLOCKED**'; OP='**[infra-operator] BLOCKED**'; RV='**[infra-reviewer] BLOCKED**'
BLK_SEQ=$'BLOCKED\nBlocked on: sequencing of steps 2 and 3'

# ---- positives
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$PL"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
both "positive planner sequencing DECISION" yes "$PL"
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$OP"$'\n'$'BLOCKED\nBlocked on: plan defect in step 2')" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
both "positive operator plan defect DECISION" yes "$OP"
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$PL"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "${DEC/DECISION/JP CONFIRMED}")"
check_kind "positive JP CONFIRMED" "" "$PL" '**[project-manager] JP CONFIRMED**'
build "$BODY_OK" "$(c 0 2025-12-31T00:00:00Z $'**[infra-planner] PLAN READY**\n### Step 1\nTarget environment: prod')" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$PL"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
both "only the LATEST PLAN READY counts (older prod plan ignored)" yes "$PL"

# ---- negatives (each stays gate)
build $'Why: x\nno scope line' "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$PL"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
both "neg: body lacks Scope line" no "$PL"
build $'Scope: staging-only extra' "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$PL"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
both "neg: Scope line not exact" no "$PL"
for planbad in $'### Step 2\nTarget environment: prod' $'### Step 2\nenv: production' $'### Prod step 2\nrun'; do
  build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK"$'\n'"$planbad")" "$(c 3 2026-01-01T01:00:00Z "$PL"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
  both "neg: plan prod step [$(echo "$planbad" | tail -1)]" no "$PL"
done
for say in "needs prod write" "spend" "where to store the secret" "external communication"; do
  build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$PL"$'\nBLOCKED\nBlocked on: '"$say")" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
  both "neg: JP-only item [$say]" no "$PL"
done
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$PL"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "${DEC/${U}3/${U}99}")"
both "neg: Resolves points at a different comment" no "$PL"
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T03:00:00Z "$PL"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
both "neg: decision dated before BLOCKED" no "$PL"
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$PL"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "${DEC/DECISION/NOTE}")"
check_kind "neg: line-1 NOTE decision" gate "$PL" '**[project-manager] NOTE**'; check_helper "neg: NOTE" 1
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$RV"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
check_kind "neg: infra-reviewer BLOCKED" gate "$RV" '**[project-manager] DECISION**'
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z $'**[infra-operator] AWAITING GO**\nx')" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
check_kind "neg: AWAITING GO + decision" gate '**[infra-operator] AWAITING GO**' '**[project-manager] DECISION**'
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$OP"$'\nBLOCKED\nBlocked on: Held: blocked by acme/widgets#5')" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
check_kind "neg: operator Held: blocked by" gate "$OP" '**[project-manager] DECISION**'
# one decision = one resume: a second BLOCKED after the decision, decision still points at the first
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$PL"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "$DEC")" "$(c 5 2026-01-01T03:00:00Z "$PL"$'\n'"$BLK_SEQ")"
infra_staging_only acme/widgets 7 "${U}5" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "second BLOCKED needs a new decision" "helper rc != 1"

# ---- code track unchanged
build "$BODY_OK" "$(c 3 2026-01-01T01:00:00Z $'**[fullstack-developer] BLOCKED**\nx')" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
check_kind "code-track BLOCKED + decision resumes" "" '**[fullstack-developer] BLOCKED**' '**[project-manager] DECISION**'
check_kind "code-track BLOCKED, no decision: gate" gate '**[fullstack-developer] BLOCKED**' ''

# ---- operator variants of the JP-only / prod / Scope / Resolves negatives
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$OP"$'\nBLOCKED\nBlocked on: needs prod write')" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
both "neg: operator BLOCKED needs prod write" no "$OP"
build $'Why: x' "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$OP"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "$DEC")"
both "neg: operator, body lacks Scope line" no "$OP"
build "$BODY_OK" "$(c 1 2026-01-01T00:00:00Z "$PLAN_OK")" "$(c 3 2026-01-01T01:00:00Z "$OP"$'\n'"$BLK_SEQ")" "$(c 4 2026-01-01T02:00:00Z "${DEC/${U}3/${U}9}")"
both "neg: operator, Resolves points elsewhere" no "$OP"

# ---- docs (AC2, AC4, AC5): mechanical greps on the repo's own files
ROOT="$HERE/../../.."
ORCH="$ROOT/agents/orchestrator.md"; CMD="$ROOT/CLAUDE.md"
grep -q 'resume nothing on the infra track' "$ORCH" && bad "AC5: 'resume nothing on the infra track' removed" "still present" || ok
grep -q 'any infra-track `BLOCKED` except' "$ORCH" && ok || bad "AC2: carve-out qualifies infra-track BLOCKED" "carve-out not qualified with an 'except' clause"
grep -q 'any infra-track `BLOCKED` [^e]' "$ORCH" && bad "AC2: no unqualified 'any infra-track BLOCKED'" "unqualified form present" || ok
grep -E '^\| `\[infra-planner\] BLOCKED`.*(Scope: staging-only)' "$ORCH" | grep -q 'PROJECT-MANAGER\|project-manager' && ok || bad "AC2: infra table row names Scope: staging-only + project-manager decision" "row missing"
grep -q 'Scope: staging-only' "$CMD" && ok || bad "AC4: CLAUDE.md mentions Scope: staging-only" "missing"
grep -qi 'infra' "$CMD" && grep 'Scope: staging-only' "$CMD" | grep -qi 'infra' && ok || bad "AC4: CLAUDE.md ties Scope: staging-only to infra BLOCKED resume" "missing"

echo "terminal_kind.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
