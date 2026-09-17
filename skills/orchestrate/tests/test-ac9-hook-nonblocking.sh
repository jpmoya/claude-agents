# AC9 — a reporter stub that sleeps 60 seconds, invoked from a lifecycle-event hook, does not
# delay the path that calls it (test asserts the calling function returns well before the stub
# completes).
#
# Exercises the REAL hooks/report-status-hook.sh against copies of run-state.sh/report-status.sh
# laid out exactly like the real checkout — hooks/ and skills/orchestrate/ as siblings under one
# root (this is what install.sh symlinks to ~/.claude/{hooks,skills}) — so a correct
# BASH_SOURCE-relative resolution in either file finds the other, and the test stays meaningful
# whether the implementation resolves via $HOME/.claude/... or a relative ../skills/orchestrate.

HERE_AC9=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_AC9=$(cd "$HERE_AC9/../../.." && pwd)
RS_AC9="$HERE_AC9/.."

# mirror_repo_root <marker> <sleep_secs> -> prints the mirrored root dir
# Builds <root>/hooks/report-status-hook.sh (real) and <root>/skills/orchestrate/{config.sh,
# run-state.sh (real), report-status.sh (fake: touches <marker> then sleeps <sleep_secs>)}.
mirror_repo_root() {
  local marker=$1 sleep_secs=$2 root
  root=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-root.XXXXXX")
  mkdir -p "$root/hooks" "$root/skills/orchestrate"
  cp "$ROOT_AC9/hooks/report-status-hook.sh" "$root/hooks/report-status-hook.sh"
  cp "$RS_AC9/config.sh" "$root/skills/orchestrate/config.sh"
  cp "$RS_AC9/run-state.sh" "$root/skills/orchestrate/run-state.sh"
  cat > "$root/skills/orchestrate/report-status.sh" <<EOF
#!/bin/bash
touch "$marker"
sleep $sleep_secs
EOF
  chmod +x "$root/skills/orchestrate/report-status.sh" "$root/hooks/report-status-hook.sh"
  echo "$root"
}

test_ac9_hook_returns_before_slow_reporter_completes() {
  local marker home root rc dur start end
  home=$(new_home)
  marker=$(mktemp -u "${TMPDIR:-/tmp}/orch-reporter-started.XXXXXX")
  # AC9's literal fixture is a reporter that sleeps 60s; shortened to 5s to keep the suite fast —
  # the assertion is about the CALLER's return time (well under the sleep), so the exact number
  # doesn't change what's being proven.
  root=$(mirror_repo_root "$marker" 5)

  # Symlink ~/.claude -> the mirrored root, so both "$HOME/.claude/skills/orchestrate/..." and
  # "$(dirname hook)/../skills/orchestrate/..." resolution strategies find the real files.
  mkdir -p "$home"
  ln -s "$root" "$home/.claude"

  start=$(date +%s)
  ( cd /tmp && PIPELINE_ISSUE=999 HOME="$home" PIPE="$root/pipe" QUEUE="$root/pipe/queue" \
    bash "$root/hooks/report-status-hook.sh" )
  rc=$?
  end=$(date +%s)
  dur=$((end - start))

  # poll briefly for the reporter having actually started (it may be backgrounded)
  local tries=0
  while [ $tries -lt 20 ] && [ ! -e "$marker" ]; do sleep 0.2; tries=$((tries + 1)); done
  local invoked=absent; [ -e "$marker" ] && invoked=present
  rm -rf "$root" "$home"; rm -f "$marker"

  assert_lt "$dur" 2 "AC9: the hook must return to its caller well before the (5s) reporter stub completes" || return 1
  assert_eq "$invoked" "present" "AC9: the hook must actually have triggered the reporter on this lifecycle event — a hook that does nothing would pass the timing check vacuously" || return 1
}

test_ac9_hook_without_pipeline_issue_is_a_true_noop() {
  # Same guard require-handoff-marker.sh uses: PIPELINE_ISSUE unset -> exit 0 immediately, no push.
  local marker home root rc
  home=$(new_home)
  marker=$(mktemp -u "${TMPDIR:-/tmp}/orch-reporter-started2.XXXXXX")
  root=$(mirror_repo_root "$marker" 0)
  mkdir -p "$home"
  ln -s "$root" "$home/.claude"

  ( cd /tmp && unset PIPELINE_ISSUE; HOME="$home" PIPE="$root/pipe" QUEUE="$root/pipe/queue" \
    bash "$root/hooks/report-status-hook.sh" )
  rc=$?
  sleep 0.3
  local invoked=absent; [ -e "$marker" ] && invoked=present
  rm -rf "$root" "$home"; rm -f "$marker"

  assert_exit0 "$rc" "AC9: hook with no PIPELINE_ISSUE exits 0" || return 1
  assert_eq "$invoked" "absent" "AC9: hook with no PIPELINE_ISSUE must not push at all" || return 1
}

run_test test_ac9_hook_returns_before_slow_reporter_completes
run_test test_ac9_hook_without_pipeline_issue_is_a_true_noop
