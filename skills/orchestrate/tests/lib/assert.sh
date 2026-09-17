# Minimal bash 3.2-compatible assert helper. No bats, no arrays-of-structs, no bash-4-only
# associative arrays.
# Sourced by every test file. Each test file calls run_test <name> <function> for each case;
# run-tests.sh sources every test_*.sh file, which self-registers and self-runs via run_all().
#
# Convention: a test function prints nothing on success and calls `fail "<msg>"` (which prints
# and returns 1) on the first broken assertion. A test file ends by calling each test function
# through `run_test`.

ASSERT_PASS=0
ASSERT_FAIL=0
ASSERT_FAIL_NAMES=""

fail() {  # fail <message...> — prints and returns 1; caller's test function should `return 1` right after
  printf '    FAIL: %s\n' "$*" >&2
  return 1
}

assert_eq() {  # assert_eq <actual> <expected> <label>
  if [ "$1" != "$2" ]; then fail "$3: expected [$2] got [$1]"; return 1; fi
}

assert_ne() {
  if [ "$1" = "$2" ]; then fail "$3: expected not [$2] but got it"; return 1; fi
}

assert_contains() {  # assert_contains <haystack> <needle> <label>
  case "$1" in
    *"$2"*) return 0 ;;
    *) fail "$3: expected to find [$2] in:
$1"; return 1 ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3: did NOT expect to find [$2] in:
$1"; return 1 ;;
    *) return 0 ;;
  esac
}

assert_exit0() {  # assert_exit0 <exit-code> <label>
  if [ "$1" -ne 0 ]; then fail "$2: expected exit 0, got $1"; return 1; fi
}

assert_file_exists() {
  if [ ! -e "$1" ]; then fail "$2: expected file to exist: $1"; return 1; fi
}

assert_file_absent() {
  if [ -e "$1" ]; then fail "$2: expected file to be absent: $1"; return 1; fi
}

assert_lt() {  # assert_lt <a> <b> <label> — integer compare, a < b
  if [ "$1" -ge "$2" ]; then fail "$3: expected $1 < $2"; return 1; fi
}

assert_le() {
  if [ "$1" -gt "$2" ]; then fail "$3: expected $1 <= $2"; return 1; fi
}

# run_test <name> — calls the shell function named <name>, tallies pass/fail, never aborts the suite.
run_test() {
  local name=$1
  printf '  - %s ... ' "$name"
  if "$name"; then
    printf 'ok\n'
    ASSERT_PASS=$((ASSERT_PASS + 1))
  else
    printf 'FAIL\n'
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    ASSERT_FAIL_NAMES="$ASSERT_FAIL_NAMES $name"
  fi
}
