# Issue #42 — the stall protocol's liveness test must be the Stop-hook nag file, not the stage log
# mtime (which never moves mid-run). Doc assertions against agents/orchestrator.md; tracked files only.

ROOT_SL=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ORCH_SL="$ROOT_SL/agents/orchestrator.md"

sl_cap_branch() { grep -F 'Cap hit, process alive' "$ORCH_SL" | head -1; }

test_sl_ac1_no_log_mtime_discriminator() {
  local br; br=$(sl_cap_branch)
  assert_ne "$br" "" "cap-hit branch exists" || return 1
  if printf '%s\n' "$br" | grep -qiE "log's mtime|log mtime"; then fail "AC1: cap-hit branch still reads the log mtime"; return 1; fi
  if grep -qF 'the log mtime tells them apart' "$ORCH_SL"; then fail "AC1: 'log mtime tells them apart' still present"; return 1; fi
  assert_eq 0 0 "AC1 ok"
}

test_sl_ac2_nag_file_is_discriminator() {
  local br; br=$(sl_cap_branch)
  printf '%s\n' "$br" | grep -qF '/tmp/pipeline/<N>-<agent>-nags.txt' || { fail "AC2: branch must read the nags file"; return 1; }
  printf '%s\n' "$br" | grep -qiE 'mtime' || { fail "AC2: branch must test the nag file mtime"; return 1; }
  printf '%s\n' "$br" | grep -qiE 'extend \*\*once\*\*' || { fail "AC2: extend once"; return 1; }
  printf '%s\n' "$br" | grep -qF 'tail -3' || { fail "AC2: tail -3 kept as reporting"; return 1; }
  assert_eq 0 0 "AC2 ok"
}

test_sl_ac3_stall_record_carries_nag_mtime() {
  local br; br=$(sl_cap_branch)
  printf '%s\n' "$br" | grep -qE '"outcome":"stall"' || { fail "AC3: stall outcome"; return 1; }
  printf '%s\n' "$br" | grep -qE 'nag_mtime' || { fail "AC3: stall record must carry nag_mtime"; return 1; }
  printf '%s\n' "$br" | grep -qF 'none' || { fail "AC3: nag_mtime may be none"; return 1; }
  assert_eq 0 0 "AC3 ok"
}
