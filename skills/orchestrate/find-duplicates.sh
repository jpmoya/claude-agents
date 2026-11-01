#!/bin/bash
# find-duplicates.sh — search for a pre-existing ticket BEFORE a new one is filed (JP, 2026-10-31).
# Incident: scheduler #2016 was filed, had pipeline runs attached, and only then was rejected as a
# duplicate of #1840/#1841. Every path that creates a ticket runs this first (agents call it
# directly; hooks/dedupe-ticket-guard.sh runs it on every `gh issue create` / issues POST).
#
# Usage: find-duplicates.sh <owner/repo> "<title>" ["<body or keywords>"] [--body-file F] [--exclude N]...
#
# Searches ALL issues and PRs — open and closed, any label — of the repo and its sibling repos of the
# same product (DEDUPE_REPO_GROUPS), with several GitHub searches (title keywords, the distinctive
# title words together, file/component names, quoted error text, body keywords), then ranks the
# union locally by keyword overlap (rarer words weigh more). Prints one line per candidate:
#   STRONG|POSSIBLE  owner/repo#N  issue|pr  state  title  [labels]  url
# Exit 1: at least one STRONG candidate. Exit 0: none. Exit 2: usage. Exit 3: every search failed.
# Output is issue metadata only (numbers, titles, states, labels, URLs) — never tokens or bodies.
set -u
command -v python3 >/dev/null 2>&1 || { echo "find-duplicates: python3 not found" >&2; exit 3; }
# Sibling repos of one product, ';' between groups, ',' within a group. Renamed repos resolve to
# their canonical name at run time (scheduler -> benjis-ops-tool, quoting tool -> sales tool).
: "${DEDUPE_REPO_GROUPS:=Benjis-Plants/scheduler,Benjis-Plants/benjis-ops-tool;Benjis-Plants/benjis-quoting-tool,Benjis-Plants/benjis-sales-tool}"
export DEDUPE_REPO_GROUPS
exec python3 -I -c '
import json, math, os, re, subprocess, sys

def usage():
    sys.stderr.write("usage: find-duplicates.sh <owner/repo> \"<title>\" [\"<body or keywords>\"] [--body-file F] [--exclude N]...\n")
    sys.exit(2)

args = sys.argv[1:]
pos, exclude, body_parts = [], set(), []
i = 0
while i < len(args):
    a = args[i]
    if a == "--exclude" and i + 1 < len(args):
        exclude.add(args[i + 1].lstrip("#")); i += 2; continue
    if a == "--body-file" and i + 1 < len(args):
        try:
            body_parts.append(open(args[i + 1], encoding="utf-8", errors="replace").read())
        except OSError:
            pass
        i += 2; continue
    pos.append(a); i += 1
if len(pos) < 2 or not re.match(r"^[\w.-]+/[\w.-]+$", pos[0]) or not pos[1].strip():
    usage()
repo, title = pos[0], pos[1]
body_parts[:0] = pos[2:3]
body = "\n".join(body_parts)

import hashlib, time
CACHE = os.environ.get("DEDUPE_CACHE_DIR") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "find-duplicates-cache-%d" % os.getuid())
def search(q):
    # The search API allows 30 calls/min for the whole account: an agent that just ran this and the
    # hook that re-runs it on the create share one result for 10 minutes instead of searching twice.
    key = os.path.join(CACHE, hashlib.sha1(q.encode()).hexdigest())
    try:
        if time.time() - os.path.getmtime(key) < 600:
            return open(key).read()
    except OSError:
        pass
    out = gh(["api", "-X", "GET", "search/issues", "-f", "q=" + q, "-f", "per_page=30",
              "--jq", "[.items[] | {number, title, state, state_reason, html_url, repository_url, body: ((.body // \"\")[0:4000]), labels: [.labels[].name], pr: (.pull_request != null)}]"])
    if out is not None:
        try:
            os.makedirs(CACHE, mode=0o700, exist_ok=True)
            with open(key, "w") as f:
                f.write(out)
        except OSError:
            pass
    return out

def gh(argv):
    try:
        p = subprocess.run(["gh"] + argv, capture_output=True, text=True, timeout=30)
    except Exception:
        return None
    return p.stdout if p.returncode == 0 else None

def canonical(r):
    out = gh(["api", "repos/" + r, "--jq", ".full_name"])
    out = (out or "").strip()
    return out if re.match(r"^[\w.-]+/[\w.-]+$", out) else r

group = [repo]
for g in os.environ.get("DEDUPE_REPO_GROUPS", "").split(";"):
    members = [m.strip() for m in g.split(",") if m.strip()]
    if repo.lower() in [m.lower() for m in members]:
        group = members
repos = []
for r in group:
    c = canonical(r)
    if c.lower() not in [x.lower() for x in repos]:
        repos.append(c)

STOP = set("""a an the and or but of to in on at by for with from into onto as is are be been being was were it its this that these those
there their then than so if when while where which who whom what why how not no nor do does did done can could should would will may might must
shall just only also too very more most less some any all each every both either one two new add adds added make makes use using used get set
once twice type types typed enter entered let instead same way time times save saves
fix fixes fixed issue ticket bug feature request support allow allows let lets show shows need needs want wants able via per after before
instead without within about again still now same other another our we you they i me my your user users app page screen tool when""".split())
# Ticket/agent boilerplate that appears in many bodies and says nothing about the problem.
STOP |= set("""acceptance criterion criteria test tests failing implement implementing blocked ambiguous comment stop guess why context
expected behavior behaviour files lane fast parent depends merging decision decisions jp pm default defaults note notes""".split()) - set(["note", "notes"])

def stem(w):
    for suf, rep in (("ies", "y"), ("ing", ""), ("ed", ""), ("es", ""), ("s", "")):
        if len(w) > len(suf) + 3 and w.endswith(suf):
            return w[: -len(suf)] + rep
    return w

def words(text):
    text = text.lower()
    text = re.sub(r"(\w)-(\w)", r"\1\2", text)   # check-out -> checkout
    return re.findall(r"[a-z][a-z0-9]+", text)

def keywords(text):
    seen, out = set(), []
    for w in words(text):
        if w in STOP or len(w) < 3:
            continue
        s = stem(w)
        if s in seen:
            continue
        seen.add(s); out.append((s, w))
    return out

ID_RE = re.compile(r"`([^`\n]{3,60})`|\b([\w-]+\.(?:tsx?|jsx?|sh|py|sql|md|json|ya?ml|css))\b|\b([a-z]+[A-Z][A-Za-z0-9]+)\b|\b([a-z0-9]+_[a-z0-9_]+)\b")
def identifiers(text):
    out = set()
    for m in ID_RE.finditer(text or ""):
        v = next(g for g in m.groups() if g).strip()
        # Code-shaped only (file, path, call, dotted/snake/camel name) — a backticked plain word or a
        # version placeholder says nothing about which component the ticket is about.
        if " " in v or not re.search(r"[._/()]|[a-z][A-Z]", v) or re.match(r"(?i)^v?(\d+|x)\.(\d+|y)", v):
            continue
        v = v.rstrip("()").split("/")[-1].lower()
        if 3 <= len(v) <= 60:
            out.add(v)
    return out

qt = keywords(title)
if not qt:
    qt = [(stem(w), w) for w in words(title)][:6]
qb = [k for k in keywords(body) if k[0] not in {s for s, _ in qt}]
qids = identifiers(title + "\n" + body)

def errtext(text):
    m = re.search(r"\"([^\"\n]{12,80})\"", text or "")
    if m and len(m.group(1).split()) >= 3:
        return m.group(1)
    m = re.search(r"(?im)^\s*(?:error|exception|typeerror|referenceerror)[:\s]+(.{12,80})$", text or "")
    return m.group(1).strip() if m else None

scope = " ".join("repo:" + r for r in repos)
# Distinctive first: longer title words before shorter ones (GitHub stems on its side, send raw words).
by_len = [w for _, w in sorted(qt, key=lambda k: -len(k[1]))]
queries = []
if qt:
    queries.append(scope + " " + " OR ".join([w for _, w in qt][:6]) + " in:title")
if len(by_len) >= 2:
    queries.append(scope + " " + " ".join(by_len[:3]))
ids_q = sorted(qids, key=lambda v: -len(v))[:5]
if ids_q:
    queries.append(scope + " " + " OR ".join("\"" + v.replace("\"", "") + "\"" for v in ids_q))
et = errtext(body)
if et:
    queries.append(scope + " \"" + et.replace("\"", "") + "\"")
elif len(qb) >= 3:
    queries.append(scope + " " + " ".join(w for _, w in sorted(qb[:12], key=lambda k: -len(k[1]))[:3]))

pool, ok = {}, 0
for q in queries:
    out = search(q[:256])
    if out is None:
        continue
    try:
        items = json.loads(out or "[]")
    except ValueError:
        continue
    ok += 1
    for it in items:
        rp = "/".join((it.get("repository_url") or "").split("/")[-2:]) or repo
        if str(it.get("number")) in exclude:
            continue
        pool.setdefault(it.get("html_url") or (rp + "#" + str(it.get("number"))), dict(it, repo=rp))
if queries and ok == 0:
    sys.stderr.write("find-duplicates: every GitHub search failed (offline or rate-limited) — no duplicate check was possible\n")
    sys.exit(3)

# Rarer words weigh more: document frequency across the fetched pool.
docs = {}
for k, it in pool.items():
    docs[k] = (set(s for s, _ in keywords(it.get("title") or "")),
               set(s for s, _ in keywords(it.get("body") or "")),
               identifiers((it.get("title") or "") + "\n" + (it.get("body") or "")))
N = max(len(docs), 1)
def weight(s):
    df = sum(1 for t, b, _ in docs.values() if s in t or s in b)
    return math.log(1.0 + (N + 1.0) / (df + 1.0))

idf = {}
for _, _, ids in docs.values():
    for v in ids:
        idf[v] = idf.get(v, 0) + 1
qts = [s for s, _ in qt]
wq = {s: weight(s) for s in qts}
wsum = sum(wq.values()) or 1.0
qbs = set(s for s, _ in qb[:20])
rows = []
for k, it in pool.items():
    t, b, ids = docs[k]
    th = [s for s in qts if s in t]
    ah = [s for s in qts if s in t or s in b]
    tw = sum(wq[s] for s in th) / wsum
    aw = sum(wq[s] for s in ah) / wsum
    # Only identifiers few other tickets mention count — a file every ticket touches is no signal.
    shared_ids = len([v for v in (qids & ids) if idf.get(v, 0) <= max(2, N // 10)])
    bo = (len(qbs & (t | b)) / len(qbs)) if qbs else 0.0
    score = 0.55 * tw + 0.2 * aw + 0.15 * min(shared_ids, 3) / 3.0 + 0.1 * bo
    strong = ((len(th) >= 3 and tw >= 0.5)
              or (len(th) >= 2 and tw >= 0.4 and shared_ids >= 1)
              or (shared_ids >= 2 and tw >= 0.25)
              or (len(th) >= 3 and aw >= 0.7 and (bo >= 0.5 or not qbs))
              or (0 < len(qts) <= 2 and len(th) == len(qts)))
    possible = strong or score >= 0.3 or len(th) >= 2
    if os.environ.get("DEDUPE_DEBUG"):
        sys.stderr.write("dbg #%s th=%d tw=%.2f aw=%.2f ids=%d bo=%.2f score=%.2f %s\n" % (it.get("number"), len(th), tw, aw, shared_ids, bo, score, sorted(v for v in qids & ids if idf.get(v, 0) <= max(2, N // 10))))
    if possible:
        rows.append((strong, score, it))
rows.sort(key=lambda r: (not r[0], -r[1]))
strong_n = sum(1 for r in rows if r[0])
print("find-duplicates: %s — searched %s (open+closed issues and PRs, any label) — %d strong, %d possible"
      % (title.strip()[:80], ", ".join(repos), strong_n, len(rows) - strong_n))
for strong, score, it in rows[:12]:
    st = it.get("state") or "?"
    if st == "closed" and it.get("state_reason"):
        st = "closed:" + it["state_reason"]
    print("%-8s %s#%s  %s  %s  %s  [%s]  %s" % ("STRONG" if strong else "POSSIBLE", it["repo"], it.get("number"),
          "pr" if it.get("pr") else "issue", st, (it.get("title") or "").replace("\n", " ")[:110],
          ", ".join(it.get("labels") or []), it.get("html_url") or ""))
sys.exit(1 if strong_n else 0)
' "$@"
