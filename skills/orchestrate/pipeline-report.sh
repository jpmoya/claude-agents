#!/usr/bin/env bash
# pipeline-report.sh [--sessions FILE]... [--events FILE]... [--since YYYY-MM-DD] [--agents-dir DIR] [--no-gh]   (issue #135, parent #134)
# One-page plain-text cost report from sessions.jsonl (written by session-backfill.sh), plus stage outcomes, blocked reasons and
# run exits from events.jsonl (written by stage-run.sh, issues #136/#141). On demand only.
# Several --sessions files are merged with the backfill's rule (cost row beats no-cost, then later end_ts).
# GITHUB TRAILS: one REST read per distinct ticket in the window. Needs bash, python3, gh (not with --no-gh).
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SESSIONS=(); EVENTS=(); SINCE=""; AGENTS_DIR="$ROOT/agents"; NO_GH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sessions) SESSIONS+=("$2"); shift 2 ;;
    --events) EVENTS+=("$2"); shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --agents-dir) AGENTS_DIR="$2"; shift 2 ;;
    --no-gh) NO_GH=1; shift ;;
    *) echo "pipeline-report.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ "${#SESSIONS[@]}" -gt 0 ] || SESSIONS=("$HOME/logs/pipeline/sessions.jsonl")
[ "${#EVENTS[@]}" -gt 0 ] || EVENTS=("$HOME/logs/pipeline/events.jsonl")
PR_EVENTS=$(printf '%s\n' "${EVENTS[@]}")
. "$ROOT/hooks/pipeline-markers.sh" >/dev/null 2>&1
MARKER_RE=$(marker_re)

PR_EVENTS="$PR_EVENTS" PR_SINCE="$SINCE" PR_AGENTS="$AGENTS_DIR" PR_NO_GH="$NO_GH" PR_MARKER_RE="$MARKER_RE" python3 - "${SESSIONS[@]}" <<'PY'
import datetime, json, os, re, subprocess, sys

since = os.environ["PR_SINCE"]
if since: since_ts = since + "T00:00:00Z"
else: since_ts = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")

def better(new, old):
    if (new.get("cost_usd") is not None) != (old.get("cost_usd") is not None): return new.get("cost_usd") is not None
    return (new.get("end_ts") or "") > (old.get("end_ts") or "")

merged = {}
for p in sys.argv[1:]:
    try: f = open(p, encoding="utf-8")
    except OSError: continue
    with f:
        for line in f:
            try: r = json.loads(line)
            except ValueError: continue
            if not isinstance(r, dict) or not r.get("session_id"): continue
            sid = r["session_id"]
            if sid not in merged or better(r, merged[sid]): merged[sid] = r
rows = [r for r in merged.values() if (r.get("start_ts") or "") >= since_ts]
c = lambda r: r.get("cost_usd") or 0
m2 = lambda x: "$%.2f" % x

print("PIPELINE REPORT  (sessions since %s: %d)" % (since_ts[:10], len(rows)))
print()
print("COST BY AGENT")
ag = {}
for r in rows:
    a = ag.setdefault(r.get("agent") or "(interactive)", [0, 0.0, 0])
    a[0] += 1; a[1] += c(r); a[2] += r.get("tool_calls") or 0
print("  %-24s %8s %10s %12s %10s" % ("agent", "sessions", "cost", "per-session", "tool-calls"))
for k, (n, cost, t) in sorted(ag.items(), key=lambda kv: (-kv[1][1], kv[0])):
    print("  %-24s %8d %10s %12s %10d" % (k, n, m2(cost), m2(cost / n), t))
print()
print("TOP 5 TICKETS BY COST")
tk = {}; un_n = 0; un_c = 0.0
for r in rows:
    if r.get("repo") and r.get("issue") is not None:
        t = tk.setdefault("%s#%s" % (r["repo"], r["issue"]), [0.0, 0]); t[0] += c(r); t[1] += 1
    else: un_n += 1; un_c += c(r)
for k, (cost, n) in sorted(tk.items(), key=lambda kv: (-kv[1][0], kv[0]))[:5]:
    print("  %-32s %10s %4d" % (k, m2(cost), n))
print("  unattributed: %d sessions, %s" % (un_n, m2(un_c)))
print()
print("CACHE HIT")
cr = sum(r.get("cache_read") or 0 for r in rows); cc = sum(r.get("cache_create") or 0 for r in rows); it = sum(r.get("in_tok") or 0 for r in rows)
den = cr + cc + it
print("  overall: %s" % ("%.3f (%.1f%%)" % (cr / den, 100.0 * cr / den) if den else "n/a"))
print()
print("COST BY MODEL")
md = {}
for r in rows:
    for k, v in (r.get("models") or {}).items(): md[k] = md.get(k, 0.0) + ((v or {}).get("cost_usd") or 0)
for k, v in sorted(md.items(), key=lambda kv: (-kv[1], kv[0])): print("  %-32s %10s" % (k, m2(v)))
print()
print("OPUS IN NON-OPUS AGENTS")
def agent_model(a):
    try:
        with open(os.path.join(os.environ["PR_AGENTS"], a + ".md"), encoding="utf-8") as f:
            if f.readline().strip() != "---": return None
            for line in f:
                if line.strip() == "---": return None
                m = re.match(r"model:\s*(.*)", line)
                if m: return m.group(1).strip()
    except OSError: return None
    return None
cache = {}; op = 0.0
for r in rows:
    a = r.get("agent")
    if not a: continue
    if a not in cache: cache[a] = agent_model(a)
    if cache[a] and "opus" not in cache[a]:
        op += sum(((v or {}).get("cost_usd") or 0) for k, v in (r.get("models") or {}).items() if "opus" in k)
print("  %s" % m2(op))

if os.environ["PR_NO_GH"] != "1":
    print()
    print("GITHUB TRAILS")
    mre = re.compile(os.environ["PR_MARKER_RE"])
    tickets = sorted({(r["repo"], r["issue"]) for r in rows if r.get("repo") and r.get("issue") is not None})
    unread = 0; deployed = first = blocked = multi = 0
    for repo, n in tickets:
        try:
            p = subprocess.run(["gh", "api", "repos/%s/issues/%s/comments?per_page=100" % (repo, n), "--paginate",
                                "--jq", '.[] | .body | split("\\n")[0]'], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        except OSError: p = None
        if p is None or p.returncode != 0: unread += 1; continue
        impl = fail = blk = dep = 0
        for ln in p.stdout.split("\n"):
            if not mre.match(ln): continue
            if re.match(r"\*\*\[fullstack-developer\] IMPLEMENTED", ln): impl += 1
            elif re.match(r"\*\*\[code-reviewer\] FAIL", ln): fail += 1
            elif re.match(r"\*\*\[deployer\] BLOCKED", ln): blk += 1
            elif re.match(r"\*\*\[deployer\] DEPLOYED", ln): dep += 1
        if blk: blocked += 1
        if impl >= 2: multi += 1
        if dep:
            deployed += 1
            if impl <= 1 and not fail and not blk: first += 1
    pct = lambda a, b: " (%d%%)" % round(100.0 * a / b) if b else ""
    print("  tickets deployed: %d" % deployed)
    print("  first-pass: %d of %d%s" % (first, deployed, pct(first, deployed)))
    print("  deployer-BLOCKED: %d of %d%s" % (blocked, len(tickets), pct(blocked, len(tickets))))
    print("  tickets with 2+ IMPLEMENTED: %d" % multi)
    print("  could not read: %d" % unread)

# ---- events.jsonl sections (stage-run.sh rows), windowed on ts by the same --since
ev = []; ev_files = 0
for p in [x for x in os.environ["PR_EVENTS"].split("\n") if x]:
    try: f = open(p, encoding="utf-8")
    except OSError: continue
    ev_files += 1
    with f:
        for line in f:
            try: r = json.loads(line)
            except ValueError: continue
            if isinstance(r, dict) and isinstance(r.get("ts"), str) and r["ts"] >= since_ts: ev.append(r)
def med(xs):
    xs = sorted(xs)
    if not xs: return 0
    n = len(xs); v = xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0
    return int(v) if v == int(v) else round(v, 1)
ends = [r for r in ev if r.get("event") == "stage_end"]
print()
print("STAGE OUTCOMES")
if not ev_files: print("  no events file")
else:
    outs = ("marker", "no_marker", "killed", "rate_limited", "error"); st = {}
    for r in ends: st.setdefault(r.get("agent") or "(unknown)", []).append(r)
    for a, rs in sorted(st.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        cnt = " ".join("%s %d" % (o, sum(1 for r in rs if r.get("outcome") == o)) for o in outs)
        print("  %-24s runs %d  %s  median_dur_s %s" % (a, len(rs), cnt, med([r["dur_s"] for r in rs if isinstance(r.get("dur_s"), (int, float))])))
print()
print("BLOCKED REASONS")
if not ev_files: print("  no events file")
else:
    bc = {}
    for r in ends:
        if r.get("block_class"): bc[r["block_class"]] = bc.get(r["block_class"], 0) + 1
    for k, v in sorted(bc.items(), key=lambda kv: (-kv[1], kv[0])): print("  %s %d" % (k, v))
    if not bc: print("  none")
print()
print("RUN EXITS AND ESCAPES")
if not ev_files: print("  no events file")
else:
    exits = [r for r in ev if r.get("event") == "run_exit"]; ex = {}
    for r in exits:
        k = r.get("class") or "(unknown)"
        if k == "rate_limited": k += " " + (r.get("limit_kind") or "unknown")
        ex[k] = ex.get(k, 0) + 1
    print("  run exits: %d" % len(exits))
    for k, v in sorted(ex.items(), key=lambda kv: (-kv[1], kv[0])): print("  %s %d" % (k, v))
    escs = [r for r in ev if r.get("event") == "escape"]
    if not escs: print("  escapes: none")
    for r in escs: print("  %s#%s caused by %s#%s" % (r.get("repo"), r.get("issue"), r.get("caused_by_repo"), r.get("caused_by_issue")))
PY
exit 0
