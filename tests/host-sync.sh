#!/bin/bash
# bin/memory-sync.py + bin/host-drift.py manifest sanity (docs/host-sync.md). No network, no real HOME.
set -u
R=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); fail=0
ok() { [ "$1" = "$2" ] && echo "  ok   $3" || { echo "  FAIL $3 (got '$1', want '$2')"; fail=1; }; }
python3 -c "import json;json.load(open('$R/infra/host-manifest.json'))" ; ok $? 0 "manifest is valid JSON"
ok "$(grep -ciE 'xox[bp]-|ghp_|gho_|eyJ' "$R/infra/host-manifest.json")" 0 "manifest holds no secret-looking values"
git init -q --bare -b main "$T/r.git"
for h in mac vm; do mkdir -p "$T/$h/.claude/pipeline"; echo "MEMORY_REMOTE=$T/r.git" > "$T/$h/.claude/pipeline/memory-sync.conf"
  e=$(echo "$T/$h" | sed 's#[/.]#-#g'); mkdir -p "$T/$h/.claude/projects/$e/memory"; echo "- [$h](x.md)" > "$T/$h/.claude/projects/$e/memory/MEMORY.md"; echo "$h" > "$T/$h/.claude/projects/$e/memory/only-$h.md"; done
echo "token = ghp_abcdefghijklmnopqrstuvwxyz0123456789" > "$(ls -d "$T"/vm/.claude/projects/*/memory)/leak.md"
s() { HOME=$T/$1 HOST_ID=$1 python3 "$R/bin/memory-sync.py" >/dev/null 2>&1; }
s mac; s vm; s mac
ok "$(ls "$T"/mac/.claude/projects/*/memory | grep -c 'only-vm.md')" 1 "vm file reached the mac"
ok "$(ls "$T"/vm/.claude/projects/*/memory | grep -c 'only-mac.md')" 1 "mac file reached the vm"
ok "$(git -C "$T/r.git" ls-tree -r --name-only main | grep -c leak)" 0 "credential-looking file was not pushed"
ok "$(grep -c . "$T"/mac/.claude/projects/*/memory/MEMORY.md)" 2 "MEMORY.md line-unioned"
rm -rf "$T"; exit $fail
