#!/usr/bin/env bash
# session-backfill.sh [--source DIR]... [--out FILE] [--min-age-min N]   (issue #135, parent #134)
# Scans Claude Code transcripts (<source>/*/*.jsonl) into one metadata row per session in sessions.jsonl.
# Reads transcripts only; never copies prompt/response text. Safe to re-run (merge on session id).
# Needs bash, python3. No flock (macOS has none): single run via a mkdir lock next to the output file.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/pipeline-lib.sh" >/dev/null 2>&1

SOURCES=(); OUT=""; MIN_AGE=60
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCES+=("$2"); shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --min-age-min) MIN_AGE="$2"; shift 2 ;;
    *) echo "session-backfill.sh: unknown argument: $1" >&2; exit 0 ;;
  esac
done
[ "${#SOURCES[@]}" -gt 0 ] || SOURCES=("$HOME/.claude/projects")
[ -n "$OUT" ] || OUT="$HOME/logs/pipeline/sessions.jsonl"
mkdir -p "$(dirname "$OUT")"

LOCK="$OUT.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  opid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -z "$opid" ] || ! kill -0 "$opid" 2>/dev/null; then why="owner pid ${opid:-unknown} is not alive"
  elif [ -n "$(find "$LOCK" -maxdepth 0 -mmin +360 2>/dev/null)" ]; then why="lock is older than 6 hours"
  else why=""; fi
  if [ -z "$why" ]; then echo "session-backfill: another run holds $LOCK (pid $opid); exiting"; exit 0; fi
  echo "session-backfill: removed stale lock $LOCK ($why)"
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || { echo "session-backfill: could not take lock $LOCK; exiting"; exit 0; }
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

HOST=$(pipeline_host)
SB_HOST="$HOST" SB_OUT="$OUT" SB_MIN_AGE="$MIN_AGE" python3 - "${SOURCES[@]}" <<'PY'
import glob, json, os, re, sys, time

host = os.environ["SB_HOST"]; out = os.environ["SB_OUT"]; min_age = float(os.environ["SB_MIN_AGE"])
bad = 0; recent = 0

def num(x):
    return int(x) if isinstance(x, float) and x == int(x) else x

def prompt_text(c):
    if isinstance(c, str): return c
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""

def attribute(p):
    repo = issue = None
    for v in re.findall(r"Repo:\s*(\S+)", p):
        v = v.rstrip(".,;)")
        if v.count("/") == 1 and not v.startswith("/") and not v.endswith("/"): repo = v
    m = re.findall(r"Issue:\s*#(\d+)", p)
    if m: issue = int(m[-1])
    if repo is None and issue is None:
        b = re.match(r"\s*Drive ([^/\s]+/[^/\s#]+)#(\d+)\s", p)
        if b: repo, issue = b.group(1), int(b.group(2))
    return repo, issue

def parse(path):
    global bad
    agent = None; prompt = None; ts_first = ts_last = None; cost = None
    msgs = {}; tools = set(); n = 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: d = json.loads(line)
            except ValueError: bad += 1; continue
            if not isinstance(d, dict): bad += 1; continue
            n += 1
            ts = d.get("timestamp")
            if isinstance(ts, str):
                ts_first = ts_first or ts; ts_last = ts
            t = d.get("type")
            if t == "agent-setting" and agent is None and isinstance(d.get("agentSetting"), str): agent = d["agentSetting"]
            elif t == "user" and prompt is None and isinstance(d.get("message"), dict): prompt = prompt_text(d["message"].get("content"))
            elif t == "cost-state": cost = d
            elif t == "assistant" and isinstance(d.get("message"), dict):
                m = d["message"]
                key = m.get("id") or ("line%d" % n)
                if isinstance(m.get("usage"), dict): msgs[key] = m["usage"]
                for b in m.get("content") or []:
                    if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("id") is not None: tools.add(b["id"])
    return agent, prompt, ts_first, ts_last, cost, msgs, tools

def build(path):
    agent, prompt, t0, t1, cost, msgs, tools = parse(path)
    if t0 is None: return None
    if cost is None and time.time() - os.path.getmtime(path) < min_age * 60:
        return "recent"
    repo, issue = attribute(prompt or "")
    models = {}
    if cost is not None:
        mu = cost.get("modelUsage") if isinstance(cost.get("modelUsage"), dict) else {}
        tot = [0, 0, 0, 0]
        for name, u in mu.items():
            r = [u.get("inputTokens", 0) or 0, u.get("outputTokens", 0) or 0,
                 u.get("cacheReadInputTokens", 0) or 0, u.get("cacheCreationInputTokens", 0) or 0]
            models[name] = {"cost_usd": u.get("costUSD"), "in_tok": r[0], "out_tok": r[1], "cache_read": r[2], "cache_create": r[3]}
            tot = [a + b for a, b in zip(tot, r)]
        api = cost.get("totalAPIDuration")
        cu = cost.get("totalCostUSD"); api_s = num(api / 1000) if isinstance(api, (int, float)) else None; src = "cost-state"
    else:
        tot = [0, 0, 0, 0]
        for u in msgs.values():
            tot = [a + (u.get(k, 0) or 0) for a, k in zip(tot, ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))]
        cu = None; api_s = None; src = "usage"
    den = tot[2] + tot[3] + tot[0]
    return {"v": 1, "host": host, "session_id": os.path.basename(path)[:-6], "project": os.path.basename(os.path.dirname(path)),
            "agent": agent, "repo": repo, "issue": issue, "start_ts": t0, "end_ts": t1,
            "cost_usd": cu, "api_s": api_s, "in_tok": tot[0], "out_tok": tot[1], "cache_read": tot[2], "cache_create": tot[3],
            "tokens_source": src, "cache_hit": round(tot[2] / den, 3) if den else None,
            "models": models, "tool_calls": len(tools)}

def better(new, old):  # cost row beats no-cost; else later end_ts; else keep old
    if (new.get("cost_usd") is not None) != (old.get("cost_usd") is not None): return new.get("cost_usd") is not None
    return (new.get("end_ts") or "") > (old.get("end_ts") or "")

existing = {}
if os.path.isfile(out):
    with open(out, encoding="utf-8") as f:
        for line in f:
            try: r = json.loads(line)
            except ValueError: continue
            if isinstance(r, dict) and r.get("session_id"): existing[r["session_id"]] = r
rows = dict(existing)
for src in sys.argv[1:]:
    for p in sorted(glob.glob(os.path.join(src, "*", "*.jsonl"))):
        try: r = build(p)
        except OSError: continue
        if r == "recent": recent += 1; continue
        if r is None: continue
        sid = r["session_id"]
        if sid not in rows or better(r, rows[sid]): rows[sid] = r

added = sum(1 for k in rows if k not in existing)
updated = sum(1 for k in rows if k in existing and rows[k] != existing[k])
ordered = sorted(rows.values(), key=lambda r: (r.get("start_ts") or "", r["session_id"]))
tmp = out + ".tmp.%d" % os.getpid()
with open(tmp, "w", encoding="utf-8") as f:
    for r in ordered: f.write(json.dumps(r, separators=(",", ":"), ensure_ascii=False) + "\n")
os.replace(tmp, out)
print("sessions.jsonl: %d rows (%d added, %d updated), %d skipped as recent, %d malformed lines skipped" % (len(ordered), added, updated, recent, bad))
PY
exit 0
