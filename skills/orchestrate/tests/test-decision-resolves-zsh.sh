# claude-agents#523 follow-up: the orchestrator calls decision_resolves_id from its Bash tool, and on the Mac that
# shell is zsh (see the marker_re note in hooks/pipeline-markers.sh). A first, bash-regex version of the helper returned
# nothing under zsh for EVERY decision (no BASH_REMATCH there), which would have stalled every delegated decision.
# These tests run the real helper and the orchestrator's real decision command under zsh and under bash.
DZ_ROOT=$(cd "$HERE/../../.." && pwd)
DZ_ID=6467612327
DZ_URL="https://github.com/owner/project-a/issues/1599#issuecomment-$DZ_ID"
DZ_OTHER="https://github.com/owner/project-a/issues/1599#issuecomment-999"
# The #1599 body that sat unrecognised for ~1h (line 2 blank, Resolves: last), and the reposted one that was accepted.
DZ_REJECTED="**[delivery-lead] DECISION**

Fast-lane tickets skip the pre-implementation gate by design. Deployer: proceed on that PASS.

Resolves: $DZ_URL"
DZ_ACCEPTED="**[delivery-lead] DECISION**
Resolves: $DZ_URL

Fast-lane tickets skip the pre-implementation gate by design. Deployer: proceed on that PASS."

dz_in() {  # dz_in <shell> <body> → "<stdout>|rc=<n>" of decision_resolves_id run in that shell
  "$1" -c '. "$1/hooks/pipeline-markers.sh"; out=$(decision_resolves_id "$2" 2>/dev/null); printf "%s|rc=%s" "$out" "$?"' _ "$DZ_ROOT" "$2"
}
dz_have_zsh() { command -v zsh >/dev/null 2>&1; }

# The incident pair: the pre-#523 rule (literal line 2 of the body) accepts one and rejects the other; the helper accepts both.
t_dz_incident_pair_old_rule_vs_helper() {
  local old_rej old_acc
  old_rej=$(jq -nr --arg b "$DZ_REJECTED" '$b | split("\n")[1]')
  old_acc=$(jq -nr --arg b "$DZ_ACCEPTED" '$b | split("\n")[1]')
  assert_ne "$old_rej" "Resolves: $DZ_URL" "old rule rejected the incident body" || return 1
  assert_eq "$old_acc" "Resolves: $DZ_URL" "old rule accepted the reposted body" || return 1
  assert_eq "$(dz_in bash "$DZ_REJECTED")" "$DZ_ID|rc=0" "helper accepts the incident body" || return 1
  assert_eq "$(dz_in bash "$DZ_ACCEPTED")" "$DZ_ID|rc=0" "helper accepts the reposted body"
}

t_dz_zsh_matches_bash_on_every_fixture() {
  dz_have_zsh || { echo "    (zsh not installed: skipped)"; return 0; }
  local name body want b z
  while IFS='|' read -r name want body; do
    body=$(printf '%b' "$body"); want="${want%;*}|rc=${want#*;}"   # fixture column is "<id>;<rc>" (| is the field separator)
    b=$(dz_in bash "$body"); z=$(dz_in zsh "$body")
    assert_eq "$b" "$want" "bash $name" || return 1
    assert_eq "$z" "$want" "zsh $name" || return 1
  done <<EOF
incident-last-line|$DZ_ID;0|**[delivery-lead] DECISION**\n\nprose\n\nResolves: $DZ_URL
line2|$DZ_ID;0|**[delivery-lead] DECISION**\nResolves: $DZ_URL\nprose
crlf|$DZ_ID;0|**[delivery-lead] DECISION**\r\n\r\nResolves: $DZ_URL\r\n
two-targets|;1|**[delivery-lead] DECISION**\nResolves: $DZ_URL\nResolves: $DZ_OTHER
quoted-only|;1|**[delivery-lead] DECISION**\n> Resolves: $DZ_URL
none|;1|**[delivery-lead] DECISION**\nprose only, see $DZ_URL
malformed|;1|**[delivery-lead] DECISION**\nResolves: the blocked comment above
EOF
}

# The orchestrator's actual decision command (agents/orchestrator.md, the `dec=$(gh issue view ...` line), run verbatim
# under zsh and bash with only `gh` stubbed: it must print the decision URL, date and the resolved id for the incident body.
t_dz_orchestrator_command_resolves_incident_in_zsh_and_bash() {
  local d bin cmd sh out want
  cmd=$(grep -F 'dec=$(gh issue view <N>' "$DZ_ROOT/agents/orchestrator.md" | head -1 | sed 's/<N>/1599/g')
  [ -n "$cmd" ] || { fail "orchestrator.md has no dec=\$(gh issue view <N> ... decision command"; return 1; }
  assert_contains "$cmd" "decision_resolves_id" "orchestrator command calls the shared helper" || return 1
  d=$(mktemp -d "${TMPDIR:-/tmp}/dz523.XXXXXX"); bin=$d/bin; mkdir -p "$bin"
  jq -n --arg dec "$DZ_REJECTED" '{comments:[{url:"https://example.invalid/dec",createdAt:"2026-10-28T13:06:39Z",body:$dec}]}' > "$d/issue.json"
  # stub gh: honour --jq like the real one (jq with -c so objects come back as one compact JSON line)
  printf '#!/bin/bash\nq=""; while [ $# -gt 0 ]; do [ "$1" = --jq ] && { q=$2; shift; }; shift; done\njq -c "$q" "%s/issue.json" | jq -r "if type==\\"string\\" then . else tojson end"\n' "$d" > "$bin/gh"; chmod +x "$bin/gh"
  want="https://example.invalid/dec
2026-10-28T13:06:39Z
$DZ_ID"
  for sh in bash zsh; do
    [ "$sh" = zsh ] && ! dz_have_zsh && continue
    out=$(PATH="$bin:$PATH" "$sh" -c '. "$1/hooks/pipeline-markers.sh"; eval "$2"' _ "$DZ_ROOT" "$cmd" 2>&1)
    assert_eq "$out" "$want" "orchestrator decision command under $sh" || { rm -rf "$d"; return 1; }
  done
  rm -rf "$d"
}

t_dz_zsh_slog_logs_ambiguous() {
  dz_have_zsh || { echo "    (zsh not installed: skipped)"; return 0; }
  local out
  out=$(zsh -c '. "$1/hooks/pipeline-markers.sh"; slog() { printf "%s\n" "$*"; }; decision_resolves_id "$2"' _ "$DZ_ROOT" "**[delivery-lead] DECISION**
Resolves: $DZ_URL
Resolves: $DZ_OTHER" 2>&1)
  assert_contains "$out" "orchestrator-decision" "zsh slog route" || return 1
  assert_contains "$out" "$DZ_ID" "zsh slog first id" || return 1
  assert_not_contains "$out" "command not found" "zsh slog no shell error"
}

for t in t_dz_incident_pair_old_rule_vs_helper t_dz_zsh_matches_bash_on_every_fixture \
  t_dz_orchestrator_command_resolves_incident_in_zsh_and_bash t_dz_zsh_slog_logs_ambiguous; do run_test "$t"; done
