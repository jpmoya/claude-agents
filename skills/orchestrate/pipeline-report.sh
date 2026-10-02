#!/usr/bin/env bash
# pipeline-report.sh [--sessions FILE]... [--since YYYY-MM-DD] [--agents-dir DIR] [--no-gh]   (issue #135, parent #134)
# One-page plain-text cost report from sessions.jsonl (written by session-backfill.sh). On demand only.
# Several --sessions files are merged with the backfill's rule (cost row beats no-cost, then later end_ts).
# GITHUB TRAILS: one REST read per distinct ticket in the window. Needs bash, python3, gh (not with --no-gh).
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SESSIONS=(); SINCE=""; AGENTS_DIR="$ROOT/agents"; NO_GH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sessions) SESSIONS+=("$2"); shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --agents-dir) AGENTS_DIR="$2"; shift 2 ;;
    --no-gh) NO_GH=1; shift ;;
    *) echo "pipeline-report.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ "${#SESSIONS[@]}" -gt 0 ] || SESSIONS=("$HOME/logs/pipeline/sessions.jsonl")
. "$ROOT/hooks/pipeline-markers.sh" >/dev/null 2>&1
MARKER_RE=$(marker_re)

PR_SINCE="$SINCE" PR_AGENTS="$AGENTS_DIR" PR_NO_GH="$NO_GH" PR_MARKER_RE="$MARKER_RE" python3 - "${SESSIONS[@]}" <<'PY'
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
PY
exit 0
