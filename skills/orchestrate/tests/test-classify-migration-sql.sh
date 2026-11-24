# Issue #820 — classify-migration-sql.sh: purely-additive migration classifier, plus the deployer.md branch that uses it.
# Fixtures under fixtures/classify-migration/ (placeholder table names only). No network, no database. A fake `curl` on PATH
# stands in for the Slack webhook; LOGDIR is a mktemp dir so no event lands in the host's real events.jsonl.

HERE_CMS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Runnable on its own (bash test-classify-migration-sql.sh) as well as sourced by run-tests.sh.
if ! declare -F run_test >/dev/null 2>&1; then
  CMS_STANDALONE=1
  . "$HERE_CMS/lib/assert.sh"
  . "$HERE_CMS/lib/fixture.sh"
fi
ROOT_CMS=$(cd "$HERE_CMS/../../.." && pwd)
SH_CMS="$ROOT_CMS/skills/orchestrate/classify-migration-sql.sh"
FX_CMS="$HERE_CMS/fixtures/classify-migration"
DEP_CMS="$ROOT_CMS/agents/deployer.md"

# cms_run <args...> — sets CMS_OUT (stdout) and CMS_RC; Slack and the events log are sandboxed.
cms_run() {
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}/cms-test.XXXXXX")
  CMS_OUT=$(LOGDIR="$d/logs" SLACK_WEBHOOK_URL="" bash "$SH_CMS" "$@" 2>"$d/err"); CMS_RC=$?
  CMS_ERR=$(cat "$d/err"); rm -rf "$d"
}

cms_additive() {  # <fixture> <kind substring>
  cms_run "$FX_CMS/$1"
  assert_eq "$CMS_RC" "0" "$1 exit" || return 1
  assert_contains "$CMS_OUT" "$FX_CMS/$1: additive (" "$1 line" || return 1
  assert_contains "$CMS_OUT" "$2" "$1 kinds" || return 1
}

cms_blocked() {  # <fixture> <expected verdict after the colon>
  cms_run "$FX_CMS/$1"
  assert_eq "$CMS_RC" "1" "$1 exit" || return 1
  assert_eq "$CMS_OUT" "$FX_CMS/$1: $2" "$1 verdict" || return 1
}

test_cms_ok_create_table()          { cms_additive ok-create-table.sql "create table"; }
test_cms_ok_create_index()          { cms_additive ok-create-index.sql "create index, create unique index"; }
test_cms_ok_create_function()       { cms_additive ok-create-function.sql "create or replace function"; }
test_cms_ok_create_policy()         { cms_additive ok-create-policy.sql "create policy"; }
test_cms_ok_create_view()           { cms_additive ok-create-view.sql "create or replace view"; }
test_cms_ok_create_trigger()        { cms_additive ok-create-trigger.sql "create trigger"; }
test_cms_ok_add_column_nullable()   { cms_additive ok-add-column-nullable.sql "alter table add column"; }
test_cms_ok_add_column_default()    { cms_additive ok-add-column-default.sql "alter table add column"; }
test_cms_ok_grant_created()         { cms_additive ok-grant-created.sql "create table, alter table enable row level security, grant"; }
test_cms_ok_grant_service_role_without_rls() { cms_additive ok-grant-service-role-no-rls.sql "create table, grant"; }
test_cms_ok_lowercase()             { cms_additive ok-lowercase.sql "create table, alter table enable row level security, create index"; }
test_cms_ok_enable_rls()            { cms_additive ok-enable-rls.sql "enable row level security"; }
test_cms_ok_multi_statement()       { cms_additive ok-multi.sql "create table, alter table enable row level security, create index, create policy, grant, alter table add column"; }
test_cms_ok_comments_with_drop()    { cms_additive ok-comments-with-drop.sql "create table"; }

test_cms_bad_drop_table()           { cms_blocked bad-drop-table.sql "NOT additive (drop table)"; }
test_cms_bad_drop_column()          { cms_blocked bad-drop-column.sql "NOT additive (alter table drop column)"; }
test_cms_bad_multi_clause()         { cms_blocked bad-multi-clause.sql "NOT additive (alter table drop column)"; }
test_cms_bad_truncate()             { cms_blocked bad-truncate.sql "NOT additive (truncate)"; }
test_cms_bad_delete()               { cms_blocked bad-delete.sql "NOT additive (delete)"; }
test_cms_bad_update()               { cms_blocked bad-update.sql "NOT additive (update)"; }
test_cms_bad_insert()               { cms_blocked bad-insert.sql "NOT additive (insert)"; }
test_cms_bad_alter_column_type()    { cms_blocked bad-alter-column-type.sql "NOT additive (alter table alter column type)"; }
test_cms_bad_set_not_null()         { cms_blocked bad-set-not-null.sql "NOT additive (alter table alter column set not null)"; }
test_cms_bad_add_column_not_null()  { cms_blocked bad-add-column-not-null.sql "NOT additive (alter table add column not null without default)"; }
test_cms_bad_rename_column()        { cms_blocked bad-rename.sql "NOT additive (alter table rename column)"; }
test_cms_bad_rename_table()         { cms_blocked bad-rename-table.sql "NOT additive (alter table rename to)"; }
test_cms_bad_revoke()               { cms_blocked bad-revoke.sql "NOT additive (revoke)"; }
test_cms_bad_grant_preexisting()    { cms_blocked bad-grant-preexisting.sql "NOT additive (grant on pre-existing object)"; }
test_cms_bad_grant_if_not_exists()  { cms_blocked bad-grant-if-not-exists.sql "NOT additive (grant on pre-existing object)"; }
test_cms_bad_grant_all_tables()     { cms_blocked bad-grant-all-tables.sql "NOT additive (grant on pre-existing objects)"; }
test_cms_bad_grant_role()           { cms_blocked bad-grant-role.sql "NOT additive (grant role membership)"; }
test_cms_bad_do_block()             { cms_blocked bad-do-block.sql "NOT additive (do block)"; }
test_cms_bad_function_body_drop()   { cms_blocked bad-function-body-drop.sql "NOT additive (create function body contains drop)"; }
test_cms_bad_function_quoted_body() { cms_blocked bad-function-quoted-body.sql "NOT additive (create function body contains delete)"; }
test_cms_bad_function_dynamic()     { cms_blocked bad-function-dynamic.sql "NOT additive (create function body contains execute)"; }
test_cms_bad_add_constraint()       { cms_blocked bad-add-constraint.sql "NOT additive (alter table add constraint)"; }
test_cms_bad_begin_commit()         { cms_blocked bad-begin-commit.sql "NOT additive (begin)"; }
test_cms_bad_garbage()              { cms_blocked bad-garbage.sql "UNPARSEABLE"; }
test_cms_bad_unterminated_string()  { cms_blocked bad-unterminated-string.sql "UNPARSEABLE"; }
test_cms_bad_unterminated_dollar()  { cms_blocked bad-unterminated-dollar.sql "UNPARSEABLE"; }
test_cms_bad_empty_file()           { cms_blocked bad-empty.sql "UNPARSEABLE"; }
test_cms_bad_only_comment()         { cms_blocked bad-only-comment.sql "UNPARSEABLE"; }

# --- code-review round 1 (PR #821): grantees, policies, OR REPLACE, calls from new bodies, body statements, case ---
test_cms_bad_grant_anon_without_rls()        { cms_blocked bad-grant-anon-no-rls.sql "NOT additive (grant to anon on an object without row level security)"; }
test_cms_bad_grant_public()                  { cms_blocked bad-grant-public.sql "NOT additive (grant to public)"; }
test_cms_bad_grant_all_to_authenticated()    { cms_blocked bad-grant-all-to-authenticated.sql "NOT additive (grant to authenticated beyond row privileges)"; }
test_cms_bad_grant_truncate_to_anon()        { cms_blocked bad-grant-truncate-to-anon.sql "NOT additive (grant to anon beyond row privileges)"; }
test_cms_bad_grant_view_to_authenticated()   { cms_blocked bad-grant-view-to-authenticated.sql "NOT additive (grant to authenticated on an object without row level security)"; }
test_cms_bad_grant_unlisted_role()           { cms_blocked bad-grant-unlisted-role.sql "NOT additive (grant to an unlisted role)"; }
test_cms_bad_grant_option()                  { cms_blocked bad-grant-option.sql "NOT additive (grant with grant option or granted by)"; }
test_cms_bad_policy_on_existing_table()      { cms_blocked bad-policy-existing-table.sql "NOT additive (create policy on a table not created here)"; }
test_cms_bad_policy_using_true()             { cms_blocked bad-policy-using-true.sql "NOT additive (create policy with an unconditional clause)"; }
test_cms_bad_policy_or_true()                { cms_blocked bad-policy-or-true.sql "NOT additive (create policy with an unconditional clause)"; }
test_cms_bad_policy_literal_condition()      { cms_blocked bad-policy-literal-condition.sql "NOT additive (create policy with an unconditional clause)"; }
test_cms_bad_policy_calls_existing_function() { cms_blocked bad-policy-calls-existing-function.sql "NOT additive (create policy calls is_admin_somewhere)"; }
test_cms_bad_replace_existing_function()     { cms_blocked bad-replace-function-existing.sql "NOT additive (create or replace function on a function not created here)"; }
test_cms_bad_replace_existing_view()         { cms_blocked bad-replace-view-existing.sql "NOT additive (create or replace view on a view not created here)"; }
test_cms_bad_replace_existing_trigger()      { cms_blocked bad-replace-trigger-existing.sql "NOT additive (create or replace trigger on a trigger not created here)"; }
test_cms_bad_body_perform_existing()         { cms_blocked bad-body-perform-existing.sql "NOT additive (create function body calls wipe_table)"; }
test_cms_bad_body_select_existing()          { cms_blocked bad-body-select-existing.sql "NOT additive (create function body calls wipe_table)"; }
test_cms_bad_trigger_calls_existing_function() { cms_blocked bad-trigger-existing-function.sql "NOT additive (create trigger calling a function not created here)"; }
test_cms_bad_view_calls_existing_function()  { cms_blocked bad-view-calls-existing-function.sql "NOT additive (create view calls wipe_table)"; }
test_cms_bad_body_update()                   { cms_blocked bad-body-update.sql "NOT additive (create function body contains update)"; }
test_cms_bad_body_truncate()                 { cms_blocked bad-body-truncate.sql "NOT additive (create function body contains truncate)"; }
test_cms_bad_body_insert()                   { cms_blocked bad-body-insert.sql "NOT additive (create function body contains insert)"; }
test_cms_bad_drop_policy()                   { cms_blocked bad-drop-policy.sql "NOT additive (drop policy)"; }
test_cms_bad_drop_index()                    { cms_blocked bad-drop-index.sql "NOT additive (drop index)"; }
test_cms_bad_drop_function()                 { cms_blocked bad-drop-function.sql "NOT additive (drop function)"; }
test_cms_bad_mixed_case_drop()               { cms_blocked bad-mixed-case-drop.sql "NOT additive (drop table)"; }
test_cms_bad_mixed_case_body()               { cms_blocked bad-mixed-case-body.sql "NOT additive (create function body contains delete)"; }

test_cms_risky_list_statement_blocks() {
  cms_run "$FX_CMS/bad-risky-list.sql"                      # without the list the statement is a plain additive ADD COLUMN
  assert_eq "$CMS_RC" "0" "no list: exit" || return 1
  cms_run --shared-tables "$FX_CMS/shared-tables.txt" "$FX_CMS/bad-risky-list.sql"
  assert_eq "$CMS_RC" "1" "risky list: exit" || return 1
  assert_contains "$CMS_OUT" "NOT additive (risky list: shared table clients)" "risky list: verdict" || return 1
  cms_run --shared-tables "$FX_CMS/shared-tables.txt" "$FX_CMS/ok-create-table.sql"
  assert_eq "$CMS_RC" "0" "risky list: unrelated file still additive" || return 1
}

test_cms_risky_list_unreadable_fails_closed() {
  cms_run --shared-tables "$FX_CMS/no-such-list.txt" "$FX_CMS/ok-create-table.sql"
  assert_eq "$CMS_RC" "1" "unreadable risky list: exit" || return 1
  assert_not_contains "$CMS_OUT" ": additive" "unreadable risky list: never additive" || return 1
}

test_cms_mixed_set_exit_1_names_offender() {
  cms_run "$FX_CMS/ok-create-table.sql" "$FX_CMS/bad-drop-table.sql" "$FX_CMS/ok-enable-rls.sql"
  assert_eq "$CMS_RC" "1" "mixed exit" || return 1
  assert_contains "$CMS_OUT" "$FX_CMS/ok-create-table.sql: additive (create table)" "good file listed" || return 1
  assert_contains "$CMS_OUT" "$FX_CMS/bad-drop-table.sql: NOT additive (drop table)" "offender named" || return 1
}

test_cms_all_additive_set_exit_0() {
  cms_run "$FX_CMS/ok-create-table.sql" "$FX_CMS/ok-enable-rls.sql"
  assert_eq "$CMS_RC" "0" "all additive exit" || return 1
}

test_cms_grant_may_name_a_table_created_in_another_file_of_the_set() {
  cms_run "$FX_CMS/grant-later-file-a.sql" "$FX_CMS/grant-later-file-b.sql"
  assert_eq "$CMS_RC" "0" "same-PR grant exit" || return 1
  cms_run "$FX_CMS/grant-later-file-a.sql"
  assert_eq "$CMS_RC" "1" "the grant alone is on a pre-existing table" || return 1
}

test_cms_no_args_exits_1() {
  cms_run
  assert_eq "$CMS_RC" "1" "no args" || return 1
}

# --- AC6: a failure of the tool itself is captured (event with release/environment/route tags + the existing Slack webhook) ---
cms_failure_case() {  # <label> <expected reason> <args...>; extra env via CMS_ENV_* globals
  local label=$1 reason=$2; shift 2
  local d bin; d=$(mktemp -d "${TMPDIR:-/tmp}/cms-test.XXXXXX"); bin="$d/bin"; mkdir -p "$bin"
  printf '#!/bin/bash\necho "$*" > "%s/curl-args"\ncat > /dev/null\n' "$d" > "$bin/curl"; chmod +x "$bin/curl"
  CMS_OUT=$(PATH="$bin:$PATH" LOGDIR="$d/logs" SLACK_WEBHOOK_URL="https://hooks.example.invalid/x" \
    CLASSIFY_MIGRATION_PYTHON="${CMS_PY:-python3}" bash "$SH_CMS" "$@" 2>/dev/null); CMS_RC=$?
  assert_eq "$CMS_RC" "1" "$label: exit (fail closed)" || { rm -rf "$d"; return 1; }
  assert_not_contains "$CMS_OUT" ": additive" "$label: never additive" || { rm -rf "$d"; return 1; }
  local ev="$d/logs/events.jsonl"
  assert_file_exists "$ev" "$label: events.jsonl" || { rm -rf "$d"; return 1; }
  local row; row=$(grep classify_migration_failed "$ev")
  assert_contains "$row" "\"reason\":\"$reason\"" "$label: reason" || { rm -rf "$d"; return 1; }
  assert_contains "$row" "\"route\":\"classify-migration\"" "$label: route tag" || { rm -rf "$d"; return 1; }
  assert_contains "$row" "\"environment\":\"" "$label: environment tag" || { rm -rf "$d"; return 1; }
  local sha; sha=$(git -C "$ROOT_CMS" rev-parse HEAD)
  assert_contains "$row" "\"release\":\"$sha\"" "$label: release = commit SHA" || { rm -rf "$d"; return 1; }
  assert_not_contains "$row" "$FX_CMS" "$label: no path in the event" || { rm -rf "$d"; return 1; }
  assert_file_exists "$d/curl-args" "$label: the Slack webhook was called" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_cms_unreadable_file_is_captured_and_fails_closed() {
  cms_failure_case "unreadable" "unreadable file" "$FX_CMS/no-such-file.sql"
}

test_cms_crash_is_captured_and_fails_closed() {
  CMS_PY=/nonexistent/python3 cms_failure_case "crash" "classifier crash (exit 127)" "$FX_CMS/ok-create-table.sql"
}

test_cms_python_exit_1_is_a_crash_not_a_verdict() {  # a syntax error / uncaught exception exits 1: must be captured, never read as "not additive"
  local stub; stub=$(mktemp "${TMPDIR:-/tmp}/cms-stub.XXXXXX")
  printf '#!/bin/bash\necho "Traceback (most recent call last):" >&2\nexit 1\n' > "$stub"; chmod +x "$stub"
  CMS_PY="$stub" cms_failure_case "python exit 1" "classifier crash (exit 1)" "$FX_CMS/ok-create-table.sql"
  local r=$?; rm -f "$stub"; return $r
}

test_cms_silent_exit_0_is_not_an_approval() {  # exit 0 with no additive line per file must not approve
  local stub; stub=$(mktemp "${TMPDIR:-/tmp}/cms-stub.XXXXXX")
  printf '#!/bin/bash\nexit 0\n' > "$stub"; chmod +x "$stub"
  CMS_PY="$stub" cms_failure_case "silent exit 0" "classifier output did not match its exit code" "$FX_CMS/ok-create-table.sql"
  local r=$?; rm -f "$stub"; return $r
}

test_cms_verdicts_do_not_raise_an_alert() {  # a NOT additive verdict is normal operation, not a tool failure
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}/cms-test.XXXXXX")
  LOGDIR="$d/logs" SLACK_WEBHOOK_URL="" bash "$SH_CMS" "$FX_CMS/bad-drop-table.sql" >/dev/null 2>&1
  assert_file_absent "$d/logs/events.jsonl" "no event for a plain verdict" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

# --- AC4/AC5: agents/deployer.md ---
test_cms_deployer_documents_the_additive_branch() {
  local t; t=$(cat "$DEP_CMS")
  assert_contains "$t" "Classified additive by deployer; no JP approval needed" "approval sentence" || return 1
  assert_contains "$t" "classify-migration-sql.sh" "classifier named" || return 1
  assert_contains "$t" '`Blocked on: needs_jp — destructive-migration-approval skipped while this PR changes migrations plus <path>, so the linter'"'"'s verdict cannot be trusted; JP confirms the migrations are not destructive`' "existing BLOCKED text unchanged" || return 1
}

test_cms_deployer_never_approves_linter_or_ci_edits() {
  local t; t=$(cat "$DEP_CMS")
  assert_contains "$t" 'scripts/lint-migrations.ts' "linter named in the guard" || return 1
  assert_contains "$t" '.github/workflows/*' "workflows named in the guard" || return 1
  assert_contains "$t" 'scripts/lib/*' "linter imports named in the guard" || return 1
}

test_cms_deployer_guard_snippet_behaves() {
  # run the guard exactly as written in deployer.md
  local snippet; snippet=$(awk '/^ *classifier_guard\(\) \{/ { on=1 } on { print } on && /^ *\}$/ { exit }' "$DEP_CMS")
  [ -n "$snippet" ] || { fail "deployer.md: classifier_guard function not found"; return 1; }
  local out
  out=$(bash -c "$snippet"'
    printf "%s\n" supabase/migrations/20261101_a.sql package.json vercel.json | classifier_guard; echo "rc=$?"
    printf "%s\n" supabase/migrations/20261101_a.sql scripts/lint-migrations.ts | classifier_guard; echo "rc=$?"
    printf "%s\n" supabase/migrations/20261101_a.sql scripts/lib/x.ts | classifier_guard; echo "rc=$?"
    printf "%s\n" supabase/migrations/20261101_a.sql .github/workflows/ci.yml | classifier_guard; echo "rc=$?"
    printf "%s\n" supabase/migrations/20261101_a.sql .github/migration-policy/shared-tables.txt | classifier_guard; echo "rc=$?"
    printf "%s\n" package.json | classifier_guard; echo "rc=$?"')
  assert_contains "$out" "eligible" "eligible case printed" || return 1
  assert_eq "$(printf '%s\n' "$out" | grep -c '^rc=0$')" "1" "exactly one eligible set" || return 1
  assert_eq "$(printf '%s\n' "$out" | grep -c 'ineligible: ')" "5" "five ineligible sets" || return 1
}

echo "-- classify-migration-sql.sh (issue #820)"
for t in $(grep -oE '^test_cms_[a-z0-9_]+' "${BASH_SOURCE[0]}"); do run_test "$t"; done
if [ -n "${CMS_STANDALONE:-}" ]; then
  echo "TOTAL: $ASSERT_PASS passed, $ASSERT_FAIL failed"
  [ "$ASSERT_FAIL" -eq 0 ] && exit 0 || exit 1
fi
