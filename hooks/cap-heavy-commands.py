#!/usr/bin/env python3
"""PreToolUse(Bash) hook — cap memory-heavy commands in a user systemd scope.

Why this exists:
  This VM has ~3.7 GiB RAM and NO swap. Without a cap, a runaway build/test
  exhausts memory and the kernel OOM killer fires. With no swap there's no
  slow "thrash" warning — it kills a process instantly, and it picks the
  biggest one, which can be the Claude session itself, the SSH/Zed
  connection, or otherwise stall the box.

What it does:
  Wraps known memory-heavy commands (JS build/test runners, pytest, e2e) in
    systemd-run --user --scope -p MemoryMax=... -p CPUWeight=...
  so any OOM kill is confined to that command's OWN cgroup. The session, the
  connection, and the rest of the VM are never candidates. Everything else
  passes through untouched.

Tuning / disabling:
  - Adjust MEM_MAX / CPU_WEIGHT below. If a legitimate build is ever killed
    (you'll see exit code 137 / "Killed"), raise MEM_MAX.
  - Disable by removing the PreToolUse entry in ~/.claude/settings.json,
    or via the /hooks menu.
"""
import json
import re
import shlex
import shutil
import sys

MEM_MAX = "2G"       # hard ceiling per heavy command (leaves headroom on 3.7G)
CPU_WEIGHT = "50"    # de-prioritize CPU under contention (default 100)

# JS build/test runners + python tests + the repo's e2e script.
HEAVY = re.compile(
    r"(npm|pnpm|yarn|bun)( run)? (build|test)|next build|vitest|playwright|jest|pytest|e2e-local\.sh"
)


def passthrough():
    """Emit nothing => tool input is left unchanged."""
    sys.exit(0)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        passthrough()

    tool_input = data.get("tool_input") or {}
    cmd = tool_input.get("command") or ""

    if not cmd:
        passthrough()
    if "systemd-run" in cmd:          # already wrapped — don't double-cap
        passthrough()
    if not HEAVY.search(cmd):         # not a heavy command — leave it alone
        passthrough()
    if not shutil.which("systemd-run"):   # capping unavailable — fail open
        passthrough()

    wrapped = (
        "systemd-run --user --scope --quiet --collect "
        f"-p MemoryMax={MEM_MAX} -p CPUWeight={CPU_WEIGHT} "
        f"-- bash -c {shlex.quote(cmd)}"
    )

    new_input = dict(tool_input)
    new_input["command"] = wrapped
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "updatedInput": new_input,
        }
    }))


if __name__ == "__main__":
    main()
