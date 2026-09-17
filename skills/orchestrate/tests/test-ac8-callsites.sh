# AC8 — every call site that invokes the reporter backgrounds it, redirects its output away from
# the caller, and cannot propagate a non-zero exit to the caller — grep-verifiable (all call sites
# match one documented pattern) plus a test using a reporter stub that exits 1.
#
# "One documented pattern" = report_status_async() in run-state.sh (design, issue #10 + the SA's
# NOTE correction on #10: it must resolve its own directory from its own BASH_SOURCE and source
# config.sh itself — a caller-dependent variable inside it "would look correct to the grep and
# still be broken"). So this file checks both that the three call sites use the helper (grep) and
# that the helper itself is caller-independent and swallows a failing reporter (behavioral).

HERE_AC8=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_AC8=$(cd "$HERE_AC8/../../.." && pwd)
RS_AC8="$HERE_AC8/.."

test_ac8_three_call_sites_use_report_status_async() {
  local n_orch n_sup n_hook
  n_orch=$(grep -c 'report_status_async' "$ROOT_AC8/skills/orchestrate/orchestrate.sh" 2>/dev/null)
  n_sup=$(grep -c 'report_status_async' "$ROOT_AC8/skills/orchestrate/supervisor.sh" 2>/dev/null)
  n_hook=$(grep -c 'report_status_async' "$ROOT_AC8/hooks/report-status-hook.sh" 2>/dev/null)

  # orchestrate.sh: run launched + run stopped = at least 2 call sites (design §4.4)
  [ "$n_orch" -ge 2 ] || { fail "AC8: orchestrate.sh should call report_status_async at both the launch and stop events (found $n_orch)"; return 1; }
  # supervisor.sh: tick keep-alive + queue-restart + held/gate + escalate = at least 4
  [ "$n_sup" -ge 4 ] || { fail "AC8: supervisor.sh should call report_status_async at tick/queue-restart/held/escalate (found $n_sup)"; return 1; }
  # the hook: at least one call, guarded by the PIPELINE_ISSUE check
  [ "$n_hook" -ge 1 ] || { fail "AC8: hooks/report-status-hook.sh should call report_status_async (found $n_hook)"; return 1; }

  # Once real call sites exist, none of them may shell out to report-status.sh directly — that
  # would bypass the one documented backgrounding pattern and could block or fail the caller.
  local hits
  hits=$(grep -rn 'report-status\.sh' \
    "$ROOT_AC8/skills/orchestrate/orchestrate.sh" "$ROOT_AC8/skills/orchestrate/supervisor.sh" "$ROOT_AC8/hooks/report-status-hook.sh" 2>/dev/null || true)
  assert_eq "$hits" "" "AC8: no call site should reference report-status.sh directly; only run-state.sh's report_status_async may invoke it" || return 1
}

test_ac8_hook_wired_into_settings_json() {
  local settings="$ROOT_AC8/settings.json"
  python3 - "$settings" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hooks = d.get("hooks", {})
def has_hook(event):
    for group in hooks.get(event, []):
        for h in group.get("hooks", []):
            if "report-status-hook.sh" in h.get("command", ""):
                return True
    return False
missing = [e for e in ("SessionStart", "Stop", "SubagentStop") if not has_hook(e)]
if missing:
    print("MISSING:" + ",".join(missing))
else:
    print("OK")
PY
}

test_ac8_hook_wired_into_settings_json_assert() {
  local result
  result=$(test_ac8_hook_wired_into_settings_json)
  assert_eq "$result" "OK" "AC8: report-status-hook.sh must be wired into SessionStart, Stop and SubagentStop in settings.json" || return 1
}

# Behavioral: a failing reporter must never propagate through report_status_async. We copy the
# REAL run-state.sh (whatever it is on this branch — stub today, implementation later) into an
# isolated temp dir alongside a fake report-status.sh that exits 1, deliberately WITHOUT setting
# $HERE or $LOGDIR to anything valid in the calling shell (the exact hook call-site condition the
# SA's NOTE flags) — so this only passes once report_status_async resolves its own directory via
# BASH_SOURCE and sources config.sh itself, rather than trusting a caller-supplied $HERE/$LOGDIR.
test_ac8_failing_reporter_never_propagates() {
  local tmp home marker rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-rs.XXXXXX")
  home=$(new_home)
  cp "$RS_AC8/config.sh" "$tmp/config.sh"
  cp "$RS_AC8/run-state.sh" "$tmp/run-state.sh"
  marker="$tmp/reporter-invoked"
  cat > "$tmp/report-status.sh" <<EOF
#!/bin/bash
touch "$marker"
exit 1
EOF
  chmod +x "$tmp/report-status.sh"

  # Deliberately unset HERE/LOGDIR and cd elsewhere before sourcing/calling, so the helper cannot
  # lean on caller state — only its own BASH_SOURCE-derived directory may be used.
  ( cd /tmp && unset HERE LOGDIR; HOME="$home" PIPE="$tmp/pipe" QUEUE="$tmp/pipe/queue" bash -c '
      . "'"$tmp"'/run-state.sh"
      report_status_async event
      exit $?
    ' )
  rc=$?

  sleep 1  # let a backgrounded reporter finish
  local invoked=absent; [ -e "$marker" ] && invoked=present
  rm -rf "$tmp" "$home"

  assert_exit0 "$rc" "AC8: calling report_status_async must itself return 0 to the caller even though the underlying reporter exits 1" || return 1
  assert_eq "$invoked" "present" "AC8: report_status_async must still invoke the sibling report-status.sh (self-resolved via BASH_SOURCE, not the caller's \$HERE) even when the caller sets nothing up" || return 1
}

run_test test_ac8_three_call_sites_use_report_status_async
run_test test_ac8_hook_wired_into_settings_json_assert
run_test test_ac8_failing_reporter_never_propagates
