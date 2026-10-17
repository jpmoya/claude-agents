#!/usr/bin/env bash
# #288 fix cycle: slot unit must be installable and setup must verify `enabled`, not just exit 0.
set -u
S="$(cd "$(dirname "$0")/.." && pwd)/infra/ci-runners/setup.sh"
f=0
chk() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; f=$((f+1)); fi; }
unit=$(awk '/^slot_unit_text\(\)/,/^}/' "$S")
chk "slot unit has [Install] with WantedBy=multi-user.target" '[[ $unit == *"[Install]"* && $unit == *"WantedBy=multi-user.target"* ]]'
chk "slot unit has no start limit" '[[ $unit == *StartLimitIntervalSec=0* && $unit != *StartLimitBurst=* ]]'
chk "slot unit restarts with short RestartSec" '[[ $unit == *Restart=always* && $unit == *RestartSec=* ]]'
chk "setup runs reset-failed on slots" 'grep -q "systemctl reset-failed \"gha-slot@\$i.service\"" "$S"'
chk "setup requires is-enabled to print enabled" 'grep -q "is-enabled \"gha-slot@\$i.service\" 2>/dev/null)\" = enabled" "$S"'
echo "# $f failed"; [ "$f" -eq 0 ]
