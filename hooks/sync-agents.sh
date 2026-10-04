#!/bin/bash
# SessionStart: pull the shared Claude config repo (agents, hooks, skills, CLAUDE.md, settings.json)
# and warn if any ~/.claude entry has stopped being a symlink into it.
# Never blocks or fails the session: offline/conflict just means you run with the local copy.
REPO="$HOME/dev/claude-agents"
[ -d "$HOME/claude-agents/.git" ] && REPO="$HOME/claude-agents"   # VM layout
[ -d "$REPO/.git" ] || exit 0
# A detached HEAD (e.g. a reviewer's checkout that never switched back) has no branch to fast-forward: go back to main first.
err=$({ git -C "$REPO" symbolic-ref -q HEAD >/dev/null 2>&1 || git -C "$REPO" checkout -q main; } 2>&1 \
  && git -C "$REPO" pull --ff-only --quiet 2>&1) \
  || echo "claude-config: $REPO did not update ($(printf '%s' "$err" | tail -n 1)) — running with the local copy"
for item in agents hooks skills CLAUDE.md settings.json; do
  case "$(readlink "$HOME/.claude/$item" 2>/dev/null)" in
    "$REPO/$item") ;;
    *) echo "claude-config: ~/.claude/$item is not a symlink to $REPO/$item — it is not syncing. See $REPO/README.md (Install)." ;;
  esac
done
exit 0
