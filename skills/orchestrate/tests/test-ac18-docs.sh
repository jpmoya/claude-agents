# AC18 — install.sh prints the two new config.local.sh keys (push URL, push token) under "what
# still needs you"; config.local.example.sh (placeholder alias-map entries only), SKILL.md, and
# README.md document both keys and the alias-map mechanism.
#
# install.sh is only ever grepped here, never executed — it rewrites crontab and ~/.claude/*
# symlinks on the real host.

HERE_AC18=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_AC18="$HERE_AC18/.."
ROOT_AC18=$(cd "$HERE_AC18/../../.." && pwd)

test_ac18_install_sh_todos_the_two_new_keys() {
  # "under what still needs you" = inside a todo() call, per install.sh's own convention
  # (todo() prints "  TODO ..." and increments the counter the script reports at the end).
  local url_hit token_hit
  url_hit=$(grep -nE 'todo[[:space:]]*"[^"]*STATUS_PUSH_URL' "$RS_AC18/install.sh" 2>/dev/null || true)
  token_hit=$(grep -nE 'todo[[:space:]]*"[^"]*STATUS_PUSH_TOKEN' "$RS_AC18/install.sh" 2>/dev/null || true)
  assert_ne "$url_hit" "" "AC18: install.sh must todo() STATUS_PUSH_URL under \"what still needs you\"" || return 1
  assert_ne "$token_hit" "" "AC18: install.sh must todo() STATUS_PUSH_TOKEN under \"what still needs you\"" || return 1
}

test_ac18_config_example_documents_both_keys_with_placeholders() {
  local url_hit token_hit real_leak
  url_hit=$(grep -c 'STATUS_PUSH_URL' "$RS_AC18/config.local.example.sh" 2>/dev/null)
  token_hit=$(grep -c 'STATUS_PUSH_TOKEN' "$RS_AC18/config.local.example.sh" 2>/dev/null)
  assert_ne "$url_hit" "0" "AC18: config.local.example.sh must document STATUS_PUSH_URL" || return 1
  assert_ne "$token_hit" "0" "AC18: config.local.example.sh must document STATUS_PUSH_TOKEN" || return 1
  # Placeholder alias entries only — this repo is public (AC5/AC17); "project-a"-shaped alias,
  # never a real client/repo name.
  real_leak=$(grep -nE 'Benjis-Plants|benjis-quoting-tool|Business-Intelligence|casa-verde-site|Benjis_rfp_finder' "$RS_AC18/config.local.example.sh" 2>/dev/null | grep -i 'STATUS_REPO_ALIASES' || true)
  assert_eq "$real_leak" "" "AC18: STATUS_REPO_ALIASES example entries must use placeholder names (e.g. project-a), never a real client/repo" || return 1
}

test_ac18_skill_md_documents_both_keys_and_alias_mechanism() {
  local url_hit token_hit alias_hit
  url_hit=$(grep -c 'STATUS_PUSH_URL' "$RS_AC18/SKILL.md" 2>/dev/null)
  token_hit=$(grep -c 'STATUS_PUSH_TOKEN' "$RS_AC18/SKILL.md" 2>/dev/null)
  alias_hit=$(grep -ci 'STATUS_REPO_ALIASES\|alias.map\|repo alias' "$RS_AC18/SKILL.md" 2>/dev/null)
  assert_ne "$url_hit" "0" "AC18: SKILL.md must document STATUS_PUSH_URL" || return 1
  assert_ne "$token_hit" "0" "AC18: SKILL.md must document STATUS_PUSH_TOKEN" || return 1
  assert_ne "$alias_hit" "0" "AC18: SKILL.md must document the repo alias-map mechanism" || return 1
}

test_ac18_readme_documents_both_keys_and_alias_mechanism() {
  local url_hit token_hit alias_hit
  url_hit=$(grep -c 'STATUS_PUSH_URL' "$ROOT_AC18/README.md" 2>/dev/null)
  token_hit=$(grep -c 'STATUS_PUSH_TOKEN' "$ROOT_AC18/README.md" 2>/dev/null)
  alias_hit=$(grep -ci 'STATUS_REPO_ALIASES\|alias.map\|repo alias' "$ROOT_AC18/README.md" 2>/dev/null)
  assert_ne "$url_hit" "0" "AC18: README.md must document STATUS_PUSH_URL" || return 1
  assert_ne "$token_hit" "0" "AC18: README.md must document STATUS_PUSH_TOKEN" || return 1
  assert_ne "$alias_hit" "0" "AC18: README.md must document the repo alias-map mechanism" || return 1
}

run_test test_ac18_install_sh_todos_the_two_new_keys
run_test test_ac18_config_example_documents_both_keys_with_placeholders
run_test test_ac18_skill_md_documents_both_keys_and_alias_mechanism
run_test test_ac18_readme_documents_both_keys_and_alias_mechanism
