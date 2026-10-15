#!/usr/bin/env bash
# #288 fix cycle: slot unit must be installable and setup must verify `enabled`, not just exit 0.
set -u
S="$(cd "$(dirname "$0")/.." && pwd)/infra/ci-runners/setup.sh"
f=0
chk() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; f=$((f+1)); fi; }
unit=$(awk '/^slot_unit_text\(\)/,/^}/' "$S")
chk "slot unit has [Install] with WantedBy=multi-user.target" '[[ $unit == *"[Install]"* && $unit == *"WantedBy=multi-user.target"* ]]'
chk "slot unit is start-rate limited" '[[ $unit == *StartLimitBurst=* && $unit == *StartLimitIntervalSec=* ]]'
chk "setup requires is-enabled to print enabled" 'grep -q "is-enabled \"gha-slot@\$i.service\" 2>/dev/null)\" = enabled" "$S"'
echo "# $f failed"; [ "$f" -eq 0 ]
