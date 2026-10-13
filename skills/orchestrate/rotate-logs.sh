#!/usr/bin/env bash
# rotate-logs.sh [--archive-dead]   (issue #141, parent #134)
#   (no args)       rotate what is over ROTATE_MIN_BYTES: supervisor.log and report-status.log (shift .k -> .k+1, live -> .1),
#                   and runs.jsonl (lines older than RUNS_KEEP_DAYS go to runs.jsonl.1; recent/unparseable lines stay in place)
#   --archive-dead  one-off: move the seven dead files of the older design into $LOGDIR/archive/dead-files-<YYYYMMDD>/
# Settings come from config.sh (overridable in config.local.sh). Bash 3.2 / BSD safe; python3 for dates. Deletes nothing
# except rotations older than ROTATE_KEEP.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/config.sh" 2>/dev/null
LOGDIR="${LOGDIR:-$HOME/logs/pipeline}"
ROTATE_MIN_BYTES="${ROTATE_MIN_BYTES:-1048576}"; ROTATE_KEEP="${ROTATE_KEEP:-12}"; RUNS_KEEP_DAYS="${RUNS_KEEP_DAYS:-14}"
RUNS="$HOME/.claude/pipeline/runs.jsonl"

ARCHIVE=0
case "${1:-}" in
  "") ;;
  --archive-dead) [ $# -eq 1 ] && ARCHIVE=1 || { echo "usage: rotate-logs.sh [--archive-dead]" >&2; exit 2; } ;;
  *) echo "usage: rotate-logs.sh [--archive-dead]" >&2; exit 2 ;;
esac

fsize() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# shift_rotations <base>: <base>.k -> <base>.k+1 (highest first), drop <base>.KEEP+1
shift_rotations() {
  local base=$1 k
  k=$ROTATE_KEEP
  while [ "$k" -ge 1 ]; do
    [ -e "$base.$k" ] && mv -f "$base.$k" "$base.$((k + 1))"
    k=$((k - 1))
  done
}
drop_overflow() { rm -f "$1.$((ROTATE_KEEP + 1))"; }

if [ "$ARCHIVE" = 1 ]; then
  DAY=$(date +%Y%m%d)
  DEST="$LOGDIR/archive/dead-files-$DAY"
  for rel in logs/pipeline/handoffs.jsonl logs/pipeline/dispatch.log logs/pipeline/runs \
             .claude/pipeline/dispatch.sh .claude/pipeline/run.sh .claude/pipeline/scan-backlog.sh .claude/pipeline/config.sh; do
    src="$HOME/$rel"
    [ -e "$src" ] || continue
    if [ -e "$DEST/$rel" ]; then echo "skipped $rel: already in $DEST (not overwriting)"; continue; fi
    mkdir -p "$DEST/$(dirname "$rel")" && mv "$src" "$DEST/$rel" && echo "moved $rel -> $DEST/$rel"
  done
  exit 0
fi

for f in "$LOGDIR/supervisor.log" "$LOGDIR/report-status.log"; do
  [ -f "$f" ] || continue
  [ "$(fsize "$f")" -gt "$ROTATE_MIN_BYTES" ] || continue
  shift_rotations "$f"; mv -f "$f" "$f.1"; drop_overflow "$f"
  echo "rotated $f"
done

if [ -f "$RUNS" ] && [ "$(fsize "$RUNS")" -gt "$ROTATE_MIN_BYTES" ]; then
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/rotate-logs.XXXXXX") || exit 0
  done_=0; any_old=1; try=1
  while [ "$try" -le 3 ]; do
    size0=$(fsize "$RUNS")
    n_old=$(python3 - "$RUNS" "$RUNS_KEEP_DAYS" "$TMPD/keep" "$TMPD/old" "$size0" <<'PY'
import datetime, json, sys
path, days, keep_p, old_p, size0 = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5])
cut = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
def is_old(line):
    try: r = json.loads(line)
    except ValueError: return False
    ts = r.get("ts") if isinstance(r, dict) else None
    if not isinstance(ts, str): return False
    try: d = datetime.datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    except ValueError: return False
    return d < cut
with open(path, "rb") as f: data = f.read(size0)
keep, old = [], []
for line in data.splitlines(True):
    (old if is_old(line.decode("utf-8", "replace")) else keep).append(line)
with open(keep_p, "wb") as f: f.write(b"".join(keep))
with open(old_p, "wb") as f: f.write(b"".join(old))
print(len(old))
PY
)
    if [ "${n_old:-0}" = 0 ]; then any_old=0; break; fi
    [ -n "${ROTATE_TEST_HOOK:-}" ] && "$ROTATE_TEST_HOOK" >/dev/null 2>&1
    if [ "$(fsize "$RUNS")" = "$size0" ]; then
      shift_rotations "$RUNS"
      mv -f "$TMPD/old" "$RUNS.1"; drop_overflow "$RUNS"
      mv -f "$TMPD/keep" "$RUNS"
      echo "rotated $RUNS ($n_old old lines -> runs.jsonl.1)"
      done_=1; break
    fi
    try=$((try + 1))
  done
  [ "$done_" = 0 ] && [ "$any_old" = 1 ] && echo "skipped $RUNS: file kept changing during rotation (runs.jsonl untouched)"
  rm -rf "$TMPD"
fi
exit 0
