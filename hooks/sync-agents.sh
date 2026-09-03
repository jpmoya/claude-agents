#!/bin/bash
# SessionStart: pull the shared Claude config repo (agents, hooks, skills, CLAUDE.md, settings.json)
# and warn if any ~/.claude entry has stopped being a symlink into it.
# Never blocks or fails the session: offline/conflict just means you run with the local copy.
REPO="$HOME/dev/claude-agents"
[ -d "$HOME/claude-agents/.git" ] && REPO="$HOME/claude-agents"   # VM layout
[ -d "$REPO/.git" ] || exit 0
git -C "$REPO" pull --ff-only --quiet >/dev/null 2>&1 || true
for item in agents hooks skills CLAUDE.md settings.json; do
  case "$(readlink "$HOME/.claude/$item" 2>/dev/null)" in
    "$REPO/$item") ;;
    *) echo "claude-config: ~/.claude/$item is not a symlink to $REPO/$item — it is not syncing. See $REPO/README.md (Install)." ;;
  esac
done
exit 0
