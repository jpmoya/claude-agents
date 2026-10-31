#!/bin/bash
# PreToolUse hook on Bash: JP's hard rule (2026-10-31) — every time a ticket is about to be logged,
# check first that no pre-existing ticket already covers it. Incident: scheduler #2016 (merge note
# and report at checkout) was filed, had pipeline runs attached, and only then was rejected as a
# duplicate of #1840/#1841.
#
# On `gh issue create`, `gh api repos/<o>/<r>/issues` (POST), a GraphQL `createIssue` or a curl POST
# to the issues API, runs skills/orchestrate/find-duplicates.sh on the new ticket's repo, title and
# body. Strong candidates found → the command is blocked and the candidates printed. The retry goes
# through only once the command (its body, or a shell comment) carries a line
#   Dup-check: reviewed #A, #B — differs because <reason>
# naming every strong candidate (a `Parent: owner/repo#N` line also counts for that N). No candidate
# → nothing happens. Applies to pipeline agents too (PM, adjudicator, architect, delivery lead):
# they are exactly the paths that file tickets.
INPUT=$(cat)
case "$INPUT" in
  *"gh issue create"*|*"gh api"*|*"api.github.com"*|*"issue\" \"create"*) ;;
  *) exit 0 ;;
esac
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export DEDUPE_FIND_CMD="${DEDUPE_FIND_CMD:-$HERE/../skills/orchestrate/find-duplicates.sh}"
export DEDUPE_GUARD_LOG="${DEDUPE_GUARD_LOG:-$HOME/logs/pipeline/dedupe-guard.log}"
printf '%s' "$INPUT" | python3 -I -c '
import json, os, re, shlex, subprocess, sys, tempfile, time

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
cmd = (data.get("tool_input") or {}).get("command") or ""
cwd = data.get("cwd") or os.getcwd()
if not cmd:
    sys.exit(0)

def toks(s):
    try:
        return shlex.split(s, comments=False, posix=True)
    except ValueError:
        # Unbalanced quotes (a heredoc, a multi-line body): fall back to whitespace words.
        return s.split()

def opt(tl, names):
    for i, t in enumerate(tl):
        for n in names:
            if t == n and i + 1 < len(tl):
                return tl[i + 1]
            if n.startswith("--") and t.startswith(n + "="):
                return t[len(n) + 1:]
    return None

def fields(tl):
    out = {}
    for i, t in enumerate(tl):
        if t in ("-f", "-F", "--field", "--raw-field") and i + 1 < len(tl) and "=" in tl[i + 1]:
            k, v = tl[i + 1].split("=", 1)
            out[k] = v
    return out

def readf(p):
    if not p or p == "-":
        return None
    p = os.path.expanduser(p)
    if not os.path.isabs(p):
        p = os.path.join(cwd, p)
    try:
        return open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return None

def remote_repo():
    try:
        u = subprocess.run(["git", "-C", cwd, "remote", "get-url", "origin"], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return None
    m = re.search(r"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$", u)
    return m.group(1) if m else None

# ---- find the create operation ------------------------------------------------------------------
op = None   # dict(repo, title, body)
m = re.search(r"\bgh\s+issue\s+create\b", cmd)
if m:
    tl = toks(cmd[m.end():])
    if "--help" in tl[:3] or "-h" in tl[:3]:
        sys.exit(0)
    body = opt(tl, ["--body", "-b"])
    bf = opt(tl, ["--body-file", "-F"])
    if bf:
        body = readf(bf) if bf != "-" else cmd
    op = dict(repo=opt(tl, ["--repo", "-R"]) or remote_repo(), title=opt(tl, ["--title", "-t"]), body=body)
if op is None:
    for m in re.finditer(r"\bgh\s+api\b", cmd):
        tl = toks(cmd[m.end():].split("\n|")[0])
        path = next((t for t in tl if re.match(r"^/?repos/[^/\s]+/[^/\s]+/issues/?(\?.*)?$", t)), None)
        meth = (opt(tl, ["-X", "--method"]) or "").upper()
        if path:
            f = fields(tl)
            implicit = meth == "" and (f or opt(tl, ["--input"]))
            if meth == "POST" or implicit:
                inp = readf(opt(tl, ["--input"]))
                if inp:
                    try:
                        j = json.loads(inp); f.setdefault("title", j.get("title")); f.setdefault("body", j.get("body"))
                    except ValueError:
                        pass
                f2 = re.match(r"^/?repos/([^/\s]+/[^/\s]+)/issues", path)
                op = dict(repo=f2.group(1), title=f.get("title"), body=f.get("body")); break
        elif "graphql" in tl and re.search(r"\bcreateIssue\b", cmd):
            op = dict(repo=None, title=None, body=None); break
if op is None:
    m = re.search(r"\bcurl\b.*api\.github\.com/repos/([\w.-]+/[\w.-]+)/issues(?![/\w])", cmd, re.S)
    if m and re.search(r"(-X\s*POST|--request\s+POST|\s-d\s|--data)", cmd):
        title = None
        t = re.search(r"\"title\"\s*:\s*\"((?:[^\"\\\\]|\\\\.)*)\"", cmd)
        if t:
            title = t.group(1)
        op = dict(repo=m.group(1), title=title, body=None)
if op is None:
    sys.exit(0)

# ---- acknowledgement: Dup-check line(s) and Parent: lines --------------------------------------------
text = cmd + "\n" + (op.get("body") or "")
dup_lines = re.findall(r"(?i)dup-check:\s*([^\n]*)", text)
acked, reason_ok = set(), False
for ln in dup_lines:
    acked |= set(re.findall(r"#(\d+)", ln))
    rest = re.sub(r"(?:[\w.-]+/[\w.-]+)?#\d+", " ", ln)
    if len(re.findall(r"[A-Za-z]{2,}", rest)) >= 4:
        reason_ok = True
for ln in re.findall(r"(?im)^\s*parent:\s*([^\n]*)", text):
    acked |= set(re.findall(r"#(\d+)", ln))

def log(outcome, strong=()):
    try:
        os.makedirs(os.path.dirname(os.environ["DEDUPE_GUARD_LOG"]), exist_ok=True)
        with open(os.environ["DEDUPE_GUARD_LOG"], "a") as fh:
            fh.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "repo": op.get("repo"),
                                 "title": (op.get("title") or "")[:120], "outcome": outcome, "strong": list(strong),
                                 "agent": os.environ.get("PIPELINE_AGENT") or "interactive"}) + "\n")
    except Exception:
        pass

HOWTO = ("Before filing, look at them: if one already covers this request, do NOT file — comment on it / extend its "
         "body instead (and if this belongs to a goal, add that goal label or milestone to the existing ticket). "
         "Only if every one is genuinely different, re-run the same command with a line in the body (or a shell "
         "comment) naming each of them and why:\n  Dup-check: reviewed #A, #B — differs because <reason>")

title = (op.get("title") or "").strip()
if not op.get("repo") or not title or title.startswith("$"):
    if dup_lines and reason_ok:
        log("allowed-unchecked-ack"); sys.exit(0)
    log("blocked-unparsed")
    sys.stderr.write("DUPLICATE CHECK (JP rule): this command creates a ticket but the hook could not read its repo/title "
                     "to search for an existing one. Run ~/.claude/skills/orchestrate/find-duplicates.sh <owner/repo> \"<title>\" "
                     "\"<key words>\" yourself first. " + HOWTO + "\n")
    sys.exit(2)

with tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt") as bf:
    bf.write((op.get("body") or "")[:8000])
try:
    p = subprocess.run([os.environ["DEDUPE_FIND_CMD"], op["repo"], title, "--body-file", bf.name],
                       capture_output=True, text=True, timeout=90)
    rc, out = p.returncode, p.stdout
except Exception as e:
    rc, out = 3, ""
finally:
    os.unlink(bf.name)

if rc == 0:
    log("no-candidates"); sys.exit(0)
if rc == 1:
    strong = re.findall(r"(?m)^STRONG\s+\S+?#(\d+)", out)
    missing = [n for n in strong if n not in acked]
    if not missing and reason_ok:
        log("allowed-acknowledged", strong); sys.exit(0)
    log("blocked-candidates", strong)
    lines = out.strip().split("\n")
    shown = [l for l in lines if not l.startswith("POSSIBLE")] + [l for l in lines if l.startswith("POSSIBLE")][:5]
    msg = "DUPLICATE CHECK (JP rule): tickets that may already cover this exist.\n" + "\n".join(shown) + "\n\n" + HOWTO
    if dup_lines and missing:
        msg += "\nYour Dup-check line does not name: " + ", ".join("#" + n for n in missing)
    elif dup_lines and not reason_ok:
        msg += "\nYour Dup-check line gives no reason (say in a few words how this ticket differs)."
    sys.stderr.write(msg + "\n")
    sys.exit(2)
# Search unavailable (offline, rate limit): never silently skip the check.
if dup_lines and reason_ok:
    log("allowed-unchecked-ack"); sys.exit(0)
log("blocked-search-failed")
sys.stderr.write("DUPLICATE CHECK (JP rule): the duplicate search could not run (GitHub search offline or rate-limited). "
                 "Wait a minute and re-run ~/.claude/skills/orchestrate/find-duplicates.sh " + op["repo"] + " \"" + title[:80] +
                 "\", or search by hand (gh issue list --state all --search ...), then " + HOWTO + "\n")
sys.exit(2)
'
