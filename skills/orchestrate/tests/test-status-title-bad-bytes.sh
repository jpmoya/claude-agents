# Issue #29 (host half), developer-added — a boundary the locked test-status-title.sh does not pin:
# a title file holding bytes that are not valid UTF-8. Design decision 4 says a bad title file
# means "no error, exit 0"; a decode error inside build-runs-json.py would instead empty the whole
# runs[] array, so every run on the host would vanish from the board.
#
# Self-contained (own helpers, tb_ prefix): run-tests.sh sources files in glob order and this one
# sorts before test-status-title.sh. Placeholder repo names only. Bash 3.2 portable.

HERE_TB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_TB="$HERE_TB/.."

# tb_run_field <json> <issue> <field> — the run's field; MISSING_FIELD / NORUN / INVALID_JSON.
tb_run_field() {
  python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print('INVALID_JSON'); sys.exit()
for r in d.get('runs', []):
    if str(r.get('issue')) == str(sys.argv[2]):
        print(r.get(sys.argv[3], 'MISSING_FIELD')); sys.exit()
print('NORUN')
" "$1" "$2" "$3" 2>/dev/null
}

test_tb_invalid_utf8_title_file_does_not_drop_the_runs() {
  local pipe home repoA out rc
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"
  mk_running "$pipe" 601 "$repoA"
  mk_running "$pipe" 602 "$repoA"
  printf 'Fix login redirect\n' > "$pipe/orch-601.title"   # control: a well-formed title
  printf 'caf\xe9 \xff\xfe menu\n' > "$pipe/orch-602.title"   # latin-1 / stray bytes, not UTF-8
  out=$(PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$RS_TB/report-status.sh" --print 2>/dev/null); rc=$?
  local issue601 title601 issue602
  issue601=$(tb_run_field "$out" 601 issue)
  title601=$(tb_run_field "$out" 601 title)
  issue602=$(tb_run_field "$out" 602 issue)
  cleanup_running; rm -rf "$pipe" "$home"
  assert_exit0 "$rc" "bad-bytes: --print exits 0" || return 1
  assert_eq "$issue601" "601" "bad-bytes: run #601 is still in the payload (valid JSON, runs[] not emptied)" || return 1
  assert_eq "$title601" "Fix login redirect" "bad-bytes: the well-formed title next to it is unaffected" || return 1
  assert_eq "$issue602" "602" "bad-bytes: the run with the undecodable title file is still reported" || return 1
}

run_test test_tb_invalid_utf8_title_file_does_not_drop_the_runs
