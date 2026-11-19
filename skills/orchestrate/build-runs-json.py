#!/usr/bin/env python3
# Turns derive_runs()'s TSV (issue, repo_path, state_code, pid, started_at, last_activity_at_epoch,
# restarts, stage) on stdin into the v1 payload's "runs" JSON array. Called by report-status.sh —
# a standalone file (not a heredoc) so stdin stays free to carry the TSV data.
#
# Usage: build-runs-json.py <aliases-arg> <runs-jsonl-path> [<pipe-dir> [completed]]
#   <aliases-arg>: STATUS_REPO_ALIASES entries ("owner/repo:alias"), one per line
#   <runs-jsonl-path>: ~/.claude/pipeline/runs.jsonl, for the last dispatch marker per repo+issue
#   <pipe-dir>: $PIPE, for the per-run orch-<run_key>.title file written at launch (issue #29).
#               Local files only -- this script never makes a network call.
#   completed:  emit the payload's "completed" array (issue #51) instead of "runs": the records
#               reconcile-status.sh marked closed (state_code "closed", orch-<run_key>.closed = closedAt),
#               closed within the last 7 days, newest first, first 10. Items carry "release" when
#               orch-<run_key>.release exists (issue #65).
#   staging | approved: emit the payload's "staging" / "approved" array (issue #65) from
#               <pipe-dir>/status-staging.json / status-approved.json (written by reconcile-status.sh);
#               no stdin, `[]` when the file is missing or unreadable.
#   goals:      emit the payload's "goals" array (issue #197) from <pipe-dir>/goal-<id>.json (+ .pid,
#               .held, .stopped); no stdin, `[]` when none. Local files only; spec is NOT sanitised
#               here (validate.js does that).
#   goalstall:  emit the payload's optional "goal_stall" array (status-page alert banner): why the goal queue is not moving while goals
#               wait in it. Local files only: goalqueue.json (`unreadable` registry entries, `queued`) and a bounded tail of the
#               supervisor's events.jsonl (STATUS_EVENTS_FILE; `error` events on route goal-project-scope, e.g. "the project is closed",
#               younger than GOAL_STALL_ERR_SECS). No stdin, `[]` when nothing stalls or no goal is queued. Facts only, no ages
#               (the heartbeat hash must not change every tick). The reason is the recorded text, redacted and capped.
#   cron:       emit the payload's optional "cron" array (issue #756) from the crontab text on stdin
#               (report-status.sh runs `crontab -l`) plus ~/logs/<job>/ for last run/result. On macOS it
#               also lists the user's launchd jobs (~/Library/LaunchAgents, source "launchd") and Claude
#               desktop scheduled tasks (~/.claude/scheduled-tasks, source "desktop"). Publishes only
#               {name, schedule, schedule_human, last_run, last_result, next_run, source, description?}:
#               never a command line, argument, env assignment, redirection, URL, log content or path (the
#               one argument word allowed is a lowercase slug appended to the name; `description` is the
#               script's own header comment, filtered; a hand-written CRON_DESC_FALLBACK entry fills in when
#               there is none, a CRON_DESC_OVERRIDE entry corrects a stale or cut-off one). Scan problems are counted on stderr as
#               "scan_errors=<n>" (no content) for report-status.sh to alert on.
import sys
import json
import plistlib
import subprocess
import os
import re
import datetime
import urllib.parse
import socket
import time

aliases_raw, runs_jsonl = sys.argv[1], sys.argv[2]
pipe_dir = sys.argv[3] if len(sys.argv) > 3 else ""
mode = sys.argv[4] if len(sys.argv) > 4 else ""
completed_mode = mode == "completed"
LIST_CAPS = {"staging": 60, "approved": None}  # approved is never truncated (jpmoya/claude-agents#386, #460)
RELEASE_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")

TITLE_MAX_CHARS = 140
COMPLETED_RETENTION_SECS = 7 * 86400
COMPLETED_MAX = 10

aliases = {}
for line in aliases_raw.splitlines():
    line = line.strip()
    if not line or ":" not in line:
        continue
    owner_repo, alias = line.split(":", 1)
    aliases[owner_repo] = alias


def owner_repo_for(repo_path):  # git -C <repo_path> config --get remote.origin.url -- local, no network
    try:
        out = subprocess.run(
            ["git", "-C", repo_path, "config", "--get", "remote.origin.url"],
            capture_output=True, text=True, timeout=5,
        )
        url = out.stdout.strip()
    except Exception:
        url = ""
    if not url:
        return ""
    if url.endswith("/"):
        url = url[:-1]
    if url.endswith(".git"):
        url = url[:-4]
    for prefix in ("https://github.com/", "http://github.com/", "git@github.com:"):
        if url.startswith(prefix):
            return url[len(prefix):]
    return ""


def alias_for(repo_path):  # -> (published repo string, owner/repo or "" for the marker lookup)
    owner_repo = owner_repo_for(repo_path)
    if not owner_repo:
        return "other", owner_repo
    return aliases.get(owner_repo, "other"), owner_repo


CUR_REPO = ""  # checkout path of the row being built; set by the two row loops below


def stem(issue):  # file stem of the current run: <owner>_<repo>-<N> (#318), else the legacy bare <N> (read-both fallback)
    slug = owner_repo_for(CUR_REPO) if CUR_REPO else ""
    if slug:
        k = "%s-%s" % (slug.replace("/", "_"), issue)
        for ext in ("repo", "pid", "closed"):
            if os.path.exists(os.path.join(pipe_dir, "orch-%s.%s" % (k, ext))):
                return k
    return str(issue)


def marker_for(owner_repo, issue):  # first line of <pipe-dir>/orch-<run_key>.marker (written at launch + by reconcile-status.sh), else None
    if not pipe_dir:
        return None
    try:
        with open(os.path.join(pipe_dir, "orch-%s.marker" % stem(issue)), encoding="utf-8", errors="replace") as f:
            return f.readline(256).strip() or None
    except OSError:
        return None


def title_for(issue):  # first line of <pipe-dir>/orch-<run_key>.title, stripped + capped; else ""
    if not pipe_dir:
        return ""
    try:
        with open(os.path.join(pipe_dir, "orch-%s.title" % stem(issue)), encoding="utf-8", errors="replace") as f:
            first_line = f.readline(4096)
    except OSError:
        return ""
    return first_line.strip()[:TITLE_MAX_CHARS]


def milestone_for(issue):  # first line of <pipe-dir>/orch-<run_key>.milestone, stripped + capped at 60; else ""
    if not pipe_dir:
        return ""
    try:
        with open(os.path.join(pipe_dir, "orch-%s.milestone" % stem(issue)), encoding="utf-8", errors="replace") as f:
            return f.readline(256).strip()[:60]
    except OSError:
        return ""


def iso(epoch_str):
    epoch_str = (epoch_str or "").strip()
    if not epoch_str:
        return None
    try:
        return datetime.datetime.fromtimestamp(
            int(epoch_str), tz=datetime.timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OSError, OverflowError):
        return None


# state_code -> payload state. stopped/done are never emitted (AC2) -- simply not in this map.
STATE_MAP = {"running": "running", "restarting": "restarting", "held": "held", "queued": "queued"}

# Sort priority when the run list is longer than the 20-slot cap below: currently-active work
# must never be bumped off the page by an older held/queued run just because its issue number
# glob-sorts earlier (derive_runs() walks orch-*.pid in filename order, which is a lexicographic
# string sort of the issue number, not numeric or recency order).
STATE_PRIORITY = {"running": 0, "restarting": 1, "queued": 2, "held": 3}

def load_list(kind):  # <pipe-dir>/status-<kind>.json -> list of well-formed dicts, else []
    if not pipe_dir:
        return []
    try:
        with open(os.path.join(pipe_dir, "status-%s.json" % kind), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    if not isinstance(data, list):
        return []
    return [d for d in data if isinstance(d, dict) and isinstance(d.get("issue"), int)
            and isinstance(d.get("owner_repo"), str) and d.get("owner_repo")]


def build_list(kind):
    items = []
    for d in load_list(kind):
        owner_repo = d["owner_repo"]
        items.append({
            "repo": aliases.get(owner_repo, "other"),
            "issue": d["issue"],
            "title": str(d.get("title") or "")[:TITLE_MAX_CHARS],
            "url": "https://github.com/%s/issues/%s" % (owner_repo, d["issue"]),
            "updated_at": str(d.get("updated_at") or ""),
        })
    items.sort(key=lambda i: i["updated_at"], reverse=True)
    cap = LIST_CAPS[kind]
    return items if cap is None else items[:cap]


# #272: a ticket whose mockups are skipped (SKIP MOCKUPS marker, or #701's skip-by-default with no REVIEW MOCKUPS) shows "mockups skipped (default or JP)", never "Approve mockups"
MOCKUPS_SKIPPED_LABEL = "mockups skipped (default or JP)"
NEEDS_LABELS = (MOCKUPS_SKIPPED_LABEL, "Approve mockups", "Say go", "Approve effort", "Missing credential", "Decision needed")
PARKED_REASONS = ("answered", "out_of_scope", "auto_retry")
BLOCK_CLASS_RE = re.compile(r"^[a-z_]{1,30}$")  # the class list lives in hooks/pipeline-markers.sh; status-page validate drops unknowns
ISO_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")


def state_file_for(issue, suffix):  # first line of <pipe-dir>/orch-<run_key>.<suffix>, else ""
    if not pipe_dir:
        return ""
    try:
        with open(os.path.join(pipe_dir, "orch-%s.%s" % (stem(issue), suffix)), encoding="utf-8", errors="replace") as f:
            return f.readline(64).strip()
    except OSError:
        return ""


def release_for(issue):  # first line of <pipe-dir>/orch-<run_key>.release if it is vX.Y.Z, else ""
    if not pipe_dir:
        return ""
    try:
        with open(os.path.join(pipe_dir, "orch-%s.release" % stem(issue)), encoding="utf-8", errors="replace") as f:
            text = f.readline(64).strip()
    except OSError:
        return ""
    return text if RELEASE_RE.match(text) else ""


def closed_at_for(issue):  # first line of <pipe-dir>/orch-<run_key>.closed -> (iso string, epoch) or None
    if not pipe_dir:
        return None
    try:
        with open(os.path.join(pipe_dir, "orch-%s.closed" % stem(issue)), encoding="utf-8", errors="replace") as f:
            text = f.readline(64).strip()
        epoch = datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except (OSError, ValueError):
        return None
    return text, epoch


def build_completed(rows):
    global CUR_REPO
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    items = []
    for line in rows:
        parts = line.split("\t")
        while len(parts) < 8:
            parts.append("")
        issue, repo_path, state_code = parts[0], parts[1], parts[2]
        if state_code != "closed":
            continue
        CUR_REPO = repo_path
        closed = closed_at_for(issue)
        if closed is None or now - closed[1] > COMPLETED_RETENTION_SECS:
            continue
        repo_alias, owner_repo = alias_for(repo_path)
        item = {
            "repo": repo_alias,
            "issue": int(issue) if issue.isdigit() else issue,
            "closed_at": closed[0],
            "marker": marker_for(owner_repo, issue),
        }
        title = title_for(issue)
        if title:
            item["title"] = title
            if owner_repo and issue.isdigit():
                item["url"] = "https://github.com/%s/issues/%s" % (owner_repo, issue)
        release = release_for(issue)
        if release:
            item["release"] = release
        items.append((closed[1], {k: v for k, v in item.items() if v is not None}))
    items.sort(key=lambda pair: -pair[0])
    return [item for _, item in items[:COMPLETED_MAX]]


if completed_mode:
    print(json.dumps(build_completed([l.rstrip("\n") for l in sys.stdin if l.strip()])))
    sys.exit(0)

if mode in LIST_CAPS:
    print(json.dumps(build_list(mode)))
    sys.exit(0)

# ---- backlog (issue: backlog reorder view) ---------------------------------------------------
# Standalone (non-goal) open agent-go tickets from <pipe-dir>/status-backlog.json (reconcile-status.sh,
# which already drops any ticket with a "goal: " label or LABEL_IN_PROGRESS), ordered by JP's stored
# priority (<pipe-dir>/backlog-priority.json, {"owner/repo#issue": rank}; lower rank first) and, for any
# ticket the store has no rank for, by today's milestone+issue fallback (same tiebreak supervisor.sh's
# dispatch step uses) -- so an empty/missing store still renders a sensible, stable order. A ranked
# ticket always sorts before every unranked one, matching supervisor.sh's dispatch order exactly for
# this (already-goal-filtered) list; see skills/orchestrate/lib/backlog-sort.jq for the dispatch side.
BACKLOG_CAP = 100
MILESTONE_VERSION_RE = re.compile(r"^v([0-9]+)\.([0-9]+)\.([0-9]+)")


def load_backlog_priority():
    if not pipe_dir:
        return {}
    try:
        with open(os.path.join(pipe_dir, "backlog-priority.json"), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: v for k, v in data.items()
            if isinstance(k, str) and isinstance(v, (int, float)) and not isinstance(v, bool)}


def _milestone_fallback_key(milestone, issue):
    m = MILESTONE_VERSION_RE.match(str(milestone or ""))
    if m:
        return (1, int(m.group(1)), int(m.group(2)), int(m.group(3)), issue)
    return (2, 0, 0, 0, issue)


def build_backlog():
    prio = load_backlog_priority()
    rows = []
    for d in load_list("backlog"):
        owner_repo = d["owner_repo"]
        issue = d["issue"]
        rank = prio.get("%s#%s" % (owner_repo, issue))
        item = {
            "repo": aliases.get(owner_repo, "other"),
            "issue": issue,
            "title": str(d.get("title") or "")[:TITLE_MAX_CHARS],
            "url": "https://github.com/%s/issues/%s" % (owner_repo, issue),
        }
        if isinstance(rank, (int, float)):
            item["rank"] = rank
            sort_key = (0, rank, (0, 0, 0, 0, 0))
        else:
            sort_key = (1, 0, _milestone_fallback_key(d.get("milestone"), issue))
        rows.append((sort_key, item))
    rows.sort(key=lambda pair: pair[0])
    return [item for _, item in rows[:BACKLOG_CAP]]


if mode == "backlog":
    print(json.dumps(build_backlog()))
    sys.exit(0)

# ---- cron (issue #756) -----------------------------------------------------------------------
# Optional "cron" array: the host user's scheduled jobs (crontab; on macOS also launchd and Claude desktop tasks),
# name + schedule + last run/result + next run. The command line is only ever used to find the script basename;
# it is never copied to the output.
# Log files are read for their last 50 lines to decide ok/failed; their content is never published.
CRON_MAX = 50
CRON_NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,80}$")
CRON_SCRIPT_EXTS = (".sh", ".bash", ".zsh", ".py", ".js", ".mjs", ".rb", ".pl", ".ts")
CRON_WRAPPERS = {"bash", "sh", "zsh", "dash", "env", "nice", "ionice", "nohup", "flock", "timeout",
                 "python", "python3", "node", "ruby", "perl", "sudo", "cd", "exec", "time", "chronic",
                 "setsid", "stdbuf", "xargs", "command"}
CRON_TAKES_ARG = {"cd", "flock", "timeout", "nice", "ionice"}  # the first non-option word after these is not the job
CRON_ENV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
CRON_TOKEN_RE = re.compile(r"""(?:"(?:\\.|[^"\\])*"|'[^']*'|\S)+""")  # a word: runs of quoted segments / non-space
CRON_STOP_RE = re.compile(r"^[0-9]*[<>|;&]")  # redirection, pipe, ; or a lone & (but not && / ||, handled below)
CRON_FAIL_RE = re.compile(r"\b(error|failed|traceback|fatal)\b", re.IGNORECASE)
CRON_EXIT_RE = re.compile(r"\b(?:exit(?:[ _-]?code)?|rc)\s*[=:]\s*(-?[0-9]+)\s*$", re.IGNORECASE)
CRON_LOG_TAIL_BYTES = 65536
CRON_LOG_TAIL_LINES = 50
CRON_MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
CRON_DOWS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
CRON_DAY_NAMES = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
CRON_SPECIALS = {  # name -> (human, equivalent 5-field schedule used for next_run; None = no next run)
    "@reboot": ("At boot", None),
    "@hourly": ("Hourly", "0 * * * *"),
    "@daily": ("Daily at 00:00", "0 0 * * *"),
    "@midnight": ("Daily at 00:00", "0 0 * * *"),
    "@weekly": ("Sundays at 00:00", "0 0 * * 0"),
    "@monthly": ("Monthly on day 1 at 00:00", "0 0 1 * *"),
    "@yearly": ("Yearly on 1 Jan at 00:00", "0 0 1 1 *"),
    "@annually": ("Yearly on 1 Jan at 00:00", "0 0 1 1 *"),
}


def _cron_field(text, lo, hi, names=None, dow=False):
    """One cron field -> (set of ints, starts_with_star). ValueError when malformed."""
    top = 7 if dow else hi  # day of week: 0 and 7 are both Sunday
    values, star = set(), False
    for part in text.split(","):
        rng, slash, step = part.partition("/")
        if slash and not (step.isdigit() and int(step) >= 1):
            raise ValueError("step")
        n = int(step) if slash else 1

        def num(tok):
            if names and tok.lower() in names:
                return names.index(tok.lower()) + lo
            if not tok.isdigit():
                raise ValueError("number")
            return int(tok)

        if rng == "*":
            a, b, star = lo, hi, True
        else:
            first, dash, last = rng.partition("-")
            a = num(first)
            b = num(last) if dash else (top if slash else a)
        if a < lo or b > top or a > b:
            raise ValueError("range")
        for v in range(a, b + 1, n):
            values.add(v % 7 if dow else v)
    return values, star


def parse_cron_schedule(fields):
    mins, _ = _cron_field(fields[0], 0, 59)
    hours, _ = _cron_field(fields[1], 0, 23)
    doms, dom_star = _cron_field(fields[2], 1, 31)
    months, _ = _cron_field(fields[3], 1, 12, CRON_MONTHS)
    dows, dow_star = _cron_field(fields[4], 0, 6, CRON_DOWS, dow=True)
    return {"minutes": sorted(mins), "hours": sorted(hours), "doms": doms, "months": months,
            "dows": dows, "dom_star": dom_star, "dow_star": dow_star}


def _cron_day_matches(sch, d):
    if d.month not in sch["months"]:
        return False
    dom_ok = d.day in sch["doms"]
    dow_ok = ((d.weekday() + 1) % 7) in sch["dows"]  # python Monday=0 -> cron Sunday=0
    if not sch["dom_star"] and not sch["dow_star"]:
        return dom_ok or dow_ok  # Vixie cron: both restricted -> either one matches
    return dom_ok and dow_ok


def cron_next_run(sch, now_epoch):
    """First fire time strictly after now_epoch, evaluated in the host's local timezone (TZ/DST via
    time.mktime); epoch seconds, or None when none within five years."""
    now_local = datetime.datetime.fromtimestamp(now_epoch)
    for offset in range(0, 366 * 5):
        d = now_local.date() + datetime.timedelta(days=offset)
        if not _cron_day_matches(sch, d):
            continue
        for h in sch["hours"]:
            for m in sch["minutes"]:
                cand = datetime.datetime(d.year, d.month, d.day, h, m)
                if cand > now_local:
                    return int(time.mktime(cand.timetuple()))
    return None


def _join_and(items):
    return " and ".join(items) if len(items) <= 2 else ", ".join(items[:-1]) + " and " + items[-1]


def cron_human(fields):
    """Short English reading of a 5-field schedule; 'Custom schedule' when it is not a common shape."""
    mi, h, dom, mon, dow = fields
    try:
        sch = parse_cron_schedule(fields)
    except ValueError:
        return "Custom schedule"
    if fields == ["*"] * 5:
        return "Every minute"
    if re.match(r"^\*/[0-9]+$", mi) and (h, dom, mon, dow) == ("*", "*", "*", "*"):
        return "Every %s minutes" % mi[2:]
    if re.match(r"^[0-9]+$", mi) and (h, dom, mon, dow) == ("*", "*", "*", "*"):
        return "Hourly at :%02d" % int(mi)
    if re.match(r"^[0-9]+$", mi) and re.match(r"^\*/[0-9]+$", h) and (dom, mon, dow) == ("*", "*", "*"):
        return "Every %s hours at :%02d" % (h[2:], int(mi))
    times = ["%02d:%02d" % (hh, mm) for hh in sch["hours"] for mm in sch["minutes"]]
    if mon != "*" or len(times) > 4 or "*" in mi or "*" in h:
        return "Custom schedule"
    clock = _join_and(times)
    if dom == "*" and dow == "*":
        return "Daily at %s" % clock
    if dom == "*" and dow == "1-5":
        return "Weekdays at %s" % clock
    if dom == "*":
        return "%s at %s" % (_join_and([CRON_DAY_NAMES[i] for i in sorted(sch["dows"])]), clock)
    if dow == "*" and re.match(r"^[0-9]+(,[0-9]+)*$", dom):
        return "Monthly on day %s at %s" % (_join_and(dom.split(",")), clock)
    return "Custom schedule"


def cron_script_ref(command):
    """-> (script token, the literal word right after it or None) for a crontab command, else None. The
    command line is only used to find these two words; nothing else leaves this function."""
    tokens = []
    for tok in CRON_TOKEN_RE.findall(command):
        if len(tok) >= 2 and tok[0] in "'\"" and tok[-1] == tok[0] and tok.count(tok[0]) == 2:
            tok = tok[1:-1]  # one fully quoted word, e.g. bash -lc '<command line>'
        tokens.append(tok)
    words = []  # (word, its index in tokens)
    for i, tok in enumerate(tokens):
        if tok in ("&&", "||"):
            continue
        if CRON_STOP_RE.match(tok):
            break
        if tok.startswith("-") or CRON_ENV_RE.match(tok):
            continue
        if any(c.isspace() for c in tok):  # bash -lc '<script command>': a whole command line in one word
            inner = cron_script_ref(tok)
            if inner:
                return inner
            continue
        words.append((tok, i))
    chosen, skip = None, 0
    for tok, i in words:
        base = tok.rstrip("/").rsplit("/", 1)[-1]
        if base.lower().endswith(CRON_SCRIPT_EXTS):
            chosen = (tok, i)
            break
    if chosen is None:
        for tok, i in words:
            base = tok.rstrip("/").rsplit("/", 1)[-1]
            if skip:
                skip -= 1
                continue
            if base in CRON_WRAPPERS:
                skip = 1 if base in CRON_TAKES_ARG else 0
                continue
            chosen = (tok, i)
            break
    if chosen is None:
        return None
    tok, i = chosen
    return tok, (tokens[i + 1] if i + 1 < len(tokens) else None)


def _cron_stem(token):
    """Script basename without directory or extension, if it is a valid job name."""
    base = token.rstrip("/").rsplit("/", 1)[-1]
    if not base or base in (".", ".."):
        return None
    stem = os.path.splitext(base)[0] if base.lower().endswith(CRON_SCRIPT_EXTS) else base
    return stem if CRON_NAME_RE.match(stem) else None


def cron_script_name(command):
    """Script basename (no directory, no extension) in a crontab command, else None."""
    ref = cron_script_ref(command)
    return _cron_stem(ref[0]) if ref else None


# The one word right after the script is appended to the job's name when it is a plain lowercase slug
# (`run-pricing-agent.sh valley-view` -> `run-pricing-agent-valley-view`), so the same script run with
# different arguments is told apart. Flags, paths, numbers, anything with `=` or `.` never qualify.
CRON_ARG_RE = re.compile(r"^[a-z]+(?:-[a-z]+)*$")


def _cron_arg(word):
    return word if word and len(word) <= 32 and CRON_ARG_RE.match(word) and word not in CRON_WRAPPERS else None


def parse_crontab(text):
    """-> [{name, stem, arg, schedule, human, fields-or-None, script}]; comments, blanks, env lines, malformed
    lines skipped. `script` (the script word, possibly relative) is only used to read its description."""
    jobs = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        head = line.split(None, 1)[0]
        command, schedule, human, fields = None, None, None, None
        if head.startswith("@"):
            spec = CRON_SPECIALS.get(head.lower())
            rest = line.split(None, 1)[1] if len(line.split(None, 1)) > 1 else ""
            if spec and rest:
                command, schedule, human = rest, head.lower(), spec[0]
                fields = spec[1].split() if spec[1] else None
        elif not CRON_ENV_RE.match(head):
            f = line.split(None, 5)
            if len(f) == 6:
                try:
                    parse_cron_schedule(f[:5])
                except ValueError:
                    continue
                command, schedule, human, fields = f[5], " ".join(f[:5]), cron_human(f[:5]), f[:5]
        if command is None:
            continue
        ref = cron_script_ref(command)
        stem = _cron_stem(ref[0]) if ref else None
        if not stem:
            continue
        arg = _cron_arg(ref[1])
        name = ("%s-%s" % (stem, arg))[:80] if arg else stem
        if not CRON_NAME_RE.match(name):
            name, arg = stem, None
        jobs.append({"name": name, "stem": stem, "arg": arg, "schedule": schedule, "human": human,
                     "fields": fields, "script": ref[0]})
        if len(jobs) >= CRON_MAX:
            break
    return jobs


def _epoch_iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _home():
    return os.path.realpath(os.path.expanduser("~"))


def _under_home(path):
    """The real path when it is inside the user's home directory (symlinks resolved on both sides), else None."""
    try:
        real = os.path.realpath(path)
    except (OSError, ValueError):
        return None
    home = _home()
    return real if home != os.sep and real.startswith(home + os.sep) else None


def _newest_log(d, must_contain=None):
    """-> (mtime, path) of the newest regular file in directory d (whose name contains must_contain, if given), else None."""
    if not os.path.isdir(d):
        return None
    newest = None
    with os.scandir(d) as it:
        for e in it:
            if e.is_file(follow_symlinks=False) and (not must_contain or must_contain in e.name):
                m = e.stat(follow_symlinks=False).st_mtime
                if newest is None or m > newest[0]:
                    newest = (m, e.path)
    return newest


def _log_failed(path):
    """True when the log's last 50 lines hold an error marker or a non-zero exit marker. Content is never kept."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - CRON_LOG_TAIL_BYTES))
        data = f.read()
    lines = data.decode("utf-8", errors="replace").splitlines()[-CRON_LOG_TAIL_LINES:]
    failed = any(CRON_FAIL_RE.search(l) for l in lines)
    for l in reversed(lines):  # the log's own (last) exit marker, where it has one
        em = CRON_EXIT_RE.search(l)
        if em:
            failed = failed or int(em.group(1)) != 0
            break
    return failed


def cron_last_run(stem, arg=None):
    """-> (last_run ISO-8601Z or None, 'ok' | 'failed' | 'unknown') from the newest file in ~/logs/<stem>/. A job run
    with an argument looks in ~/logs/<stem>-<arg>/ first, then only at files of ~/logs/<stem>/ whose name holds the
    argument (never at the other arguments' logs: a shared log must not flip three jobs to failed at once)."""
    logs = os.path.join(os.path.expanduser("~"), "logs")
    if arg:
        cands = [(os.path.join(logs, "%s-%s" % (stem, arg)), None), (os.path.join(logs, stem), arg)]
    else:
        cands = [(os.path.join(logs, stem), None)]
    for d, must_contain in cands:
        newest = _newest_log(d, must_contain)
        if newest:
            return _epoch_iso(newest[0]), ("failed" if _log_failed(newest[1]) else "ok")
    return None, "unknown"


# ---- description (the "What it does" column) ----
# Plain text only, from the job's script: a `# desc:` line in its first 40 lines, else the first comment line
# of its header (after the shebang). Never a command line, path or secret: a script word that is not an
# absolute / ~ / $HOME path to a real file inside the home directory yields nothing, the text is
# whitespace-collapsed and capped at 140 code points, and anything that looks like an email, URL, path, assignment
# or long token is dropped whole. The Worker applies the same rule again (validate.js CRON_DESCRIPTION_UNSAFE).
CRON_DESC_MAX = 140
CRON_DESC_UNSAFE_RE = re.compile(
    r"[<>&\"`@]|://|~/|(?:^|\s)/[\w.-]|\b[A-Za-z_][A-Za-z0-9_]*=\S|[A-Za-z0-9_+-]{32,}"
    r"|\b(?:sk|ghp|gho|xox[a-z]|AKIA)[-_A-Za-z0-9]{8,}")
CRON_DESC_EXPLICIT_RE = re.compile(r"^desc(?:ription)?\s*:\s*(.+)$", re.IGNORECASE)
# Header comment lines that are not a description: rules, lint pragmas, a usage line (`foo.sh [--flag] ...`).
CRON_DESC_NOISE_RE = re.compile(r"^(?:[-=#*_~/\s]*|shellcheck\b.*|vim?:.*|-\*-.*|eslint.*|pylint.*|noqa.*|type:.*|"
                                r"pragma.*|!.*|shfmt.*|prettier.*|set\s+-.*|usage\b.*|[\w./-]+\.(?:sh|py|js|mjs|ts|rb|pl)\b.*|"
                                r".*(?:^|\s)\[?--[a-z].*)$", re.IGNORECASE)


def clean_description(text):
    if not isinstance(text, str):
        return None
    text = re.sub(r"[\x00-\x1f\x7f\s]+", " ", text).strip()
    if len(text) < 3 or not re.search(r"[A-Za-z]", text) or CRON_DESC_UNSAFE_RE.search(text):
        return None
    if len(text) > CRON_DESC_MAX:  # cut at a word boundary where there is one, marked with an ellipsis (140 in all)
        cut = text[:CRON_DESC_MAX - 1]
        text = (cut.rsplit(" ", 1)[0] if " " in cut[CRON_DESC_MAX // 2:] else cut).rstrip(" ,;:-") + "…"
    return text or None


def resolve_script(token):
    """An absolute / ~ / $HOME path to a regular file inside the home directory -> its real path, else None."""
    if not isinstance(token, str) or not token or "\n" in token:
        return None
    home = os.path.expanduser("~")
    t = token.replace("${HOME}", home).replace("$HOME", home)
    t = os.path.expanduser(t)
    if not os.path.isabs(t):
        return None  # relative to a working directory the crontab line does not give us
    real = _under_home(t)
    return real if real and os.path.isfile(real) else None


def script_description(token):
    path = resolve_script(token)
    if not path:
        return None
    try:
        with open(path, "rb") as f:
            head = f.read(CRON_LOG_TAIL_BYTES // 16)  # 4 KB is plenty for a header comment
    except OSError:
        return None
    first, in_header = None, True
    for i, raw in enumerate(head.decode("utf-8", errors="replace").splitlines()[:40]):
        t = raw.strip()
        if i == 0 and t.startswith("#!"):
            continue
        if not t:
            continue
        if not t.startswith("#"):
            in_header = False
            continue
        body = t.lstrip("#").strip()
        m = CRON_DESC_EXPLICIT_RE.match(body)
        if m:
            return clean_description(m.group(1))  # an explicit `# desc:` line wins over the header comment
        if in_header and first is None and not CRON_DESC_NOISE_RE.match(body):
            first = body
    return clean_description(first)


# ---- curated descriptions (the fallback / correction table for "What it does") ----
# Written by hand from the jobs' real scripts, plain English, each <= 140 code points and clean under both
# filters (a test pins `clean_description(text) == text` for every entry). Keyed by the published job name.
#   CRON_DESC_FALLBACK  used only when the script / SKILL.md gave nothing (a header added later wins).
#   CRON_DESC_OVERRIDE  wins even over a header: for a header that is stale (layoff-scan-cron says "Daily", it
#                       runs on Mondays) or cut off / boilerplate (supervisor, message-triage, github-runner-mobile).
CRON_DESC_FALLBACK = {
    # VM crontab
    "run-pricing-agent-valley-view": "Weekly Valley View supplier price sync: the pricing agent updates product prices and flags big changes.",
    "run-pricing-agent-greenville": "Quarterly Greenville supplier pricing agent: refreshes product prices and flags large changes for review.",
    "run-pricing-agent-lechuza": "Quarterly Lechuza supplier pricing agent: refreshes product prices and flags large changes for review.",
    "payroll-sync": "Every other Tuesday, pushes staff timesheet hours into QuickBooks Online and posts the payroll summary to Slack.",
    "scan-backlog": "Hourly pipeline backlog scan: labels new open issues as proposed and posts a digest to Slack.",
    "message-triage-run": "Triages the owner's Gmail and Slack messages with the message-triage agent, hourly early on, then every 10 minutes.",
    "interview-coordinator-run": "Every 4 hours, screens new candidates, follows up on open outreach and books interviews for open postings.",
    # both hosts
    "host-drift": "Daily check that this machine's agent setup matches the shared manifest; fixes safe drift and opens one issue if it finds more.",
    "memory-sync": "Hourly sync of Claude memory notes between the Mac and the VM through one private git remote; never deletes anything.",
    "rotate-logs": "Rotates the pipeline logs once they grow past a size limit and trims old runs from the run history.",
    # Mac crontab
    "session-backfill": "Daily scan of Claude session transcripts into one metadata row per session (agent, timing, cost) for pipeline cost reports.",
    # Mac launchd
    "qbo-scraper": "Scrapes payroll figures from QuickBooks Online several times on Thursdays and Fridays.",
    "cd-proof": "Every 5 minutes, relaunches the continuous-deployment proof delivery lead if it died, until its done file appears.",
    "pm-release341": "Old 30-minute project-manager cycle for the release 3.4.1 plan; its script no longer exists, so it does nothing now.",
    "weekly-cache-cleanup": "Mondays at 09:00, clears the npm, Wispr Flow, Spotify and Claude desktop caches to free disk space.",
}
CRON_DESC_OVERRIDE = {
    "layoff-scan-cron": "Weekly, on Mondays: searches for layoffs and closures at related companies and posts new finds to Slack for recruiting.",
    "supervisor": "Pipeline supervisor, every 2 minutes: restarts exited runs, drains the queue, dispatches approved issues and reconciles status.",
    "pipeline-supervisor": "Pipeline supervisor, every 2 minutes: restarts exited runs, drains the queue, dispatches approved issues and reconciles status.",
    "message-triage": "Every 15 minutes, runs the message-triage agent on the Mac to triage the owner's Gmail and Slack messages.",
    "github-runner-mobile": "Keeps the Mac GitHub Actions runner for mobile builds running.",
}


def curated_description(name, scanned):
    """The description to publish for job `name`: a CRON_DESC_OVERRIDE entry, else what the script / SKILL.md gave,
    else a CRON_DESC_FALLBACK entry. Curated text goes through clean_description like everything else."""
    if name in CRON_DESC_OVERRIDE:
        return clean_description(CRON_DESC_OVERRIDE[name]) or scanned
    return scanned or clean_description(CRON_DESC_FALLBACK.get(name))


# ---- launchd (macOS only): ~/Library/LaunchAgents/com.{jp,benjis,jpmoya,xaki}.*.plist ----
LAUNCHD_PREFIXES = ("com.jp.", "com.benjis.", "com.jpmoya.", "com.xaki.")  # not Google / homebrew / retired ones
LAUNCHD_FIELDS = (("Minute", 0, 59), ("Hour", 0, 23), ("Day", 1, 31), ("Month", 1, 12), ("Weekday", 0, 7))


def _cron_dir(env_name, default):
    """A collector directory: the default, an override (test hook), or None when the override is empty (= off)."""
    v = os.environ.get(env_name)
    return default if v is None else (v or None)


def _is_darwin():
    return (os.environ.get("STATUS_CRON_PLATFORM") or sys.platform) == "darwin"  # env: test hook only


def _cron_field_text(values, lo, hi):
    vals = sorted(values)
    if len(vals) >= 3:
        step = vals[1] - vals[0]
        if step >= 1 and all(b - a == step for a, b in zip(vals, vals[1:])):
            if step == 1:
                return "%d-%d" % (vals[0], vals[-1])
            if vals[0] == lo and vals[-1] + step > hi:
                return "*/%d" % step
            return "%d-%d/%d" % (vals[0], vals[-1], step)
    return ",".join(str(v) for v in vals)


def launchd_calendar(spec):
    """StartCalendarInterval (a dict, or a list of dicts) -> cron fields [min, hour, dom, month, dow] when it is
    exactly a cron-shaped cross product, else None. A missing key is a wildcard, as in launchd."""
    dicts = [spec] if isinstance(spec, dict) else spec
    if not isinstance(dicts, list) or not dicts or not all(isinstance(d, dict) and d for d in dicts):
        return None
    sets, product = [], 1
    for key, lo, hi in LAUNCHD_FIELDS:
        present = [key in d for d in dicts]
        if not any(present):
            sets.append(None)
            continue
        if not all(present):
            return None  # some entries constrain this field and others do not: not a cross product
        vals = set()
        for d in dicts:
            v = d[key]
            if isinstance(v, bool) or not isinstance(v, int) or v < lo or v > hi:
                return None
            vals.add(0 if key == "Weekday" and v == 7 else v)
        sets.append(vals)
        product *= len(vals)
    if len({tuple(sorted(d.items())) for d in dicts}) != len(dicts) or product != len(dicts):
        return None
    if sets[2] is not None and sets[4] is not None:
        return None  # day-of-month and weekday together: cron ORs them, launchd does not
    if sets[0] is None and any(v is not None for v in sets[1:]):
        return None  # no Minute means every minute of the matching hours or days: not a schedule worth a cron reading
    fields = []
    for (key, lo, hi), vals in zip(LAUNCHD_FIELDS, sets):
        fields.append("*" if vals is None else _cron_field_text(vals, lo, 6 if key == "Weekday" else hi))
    return fields


def _every_minutes_human(fields):
    """`1-59/2 * * * *` / `*/5 * * * *` style (only the minute set varies) -> 'Every N minutes', else None."""
    if fields[1:] != ["*"] * 4:
        return None
    try:
        mins = sorted(parse_cron_schedule(fields)["minutes"])
    except ValueError:
        return None
    if len(mins) < 3:
        return None
    step = mins[1] - mins[0]
    if step >= 1 and all(b - a == step for a, b in zip(mins, mins[1:])) and mins[0] < step and mins[-1] + step >= 60:
        return "Every %d minutes" % step
    return None


def _interval_human(secs):
    if secs % 3600 == 0:
        h = secs // 3600
        return "Hourly" if h == 1 else "Every %d hours" % h
    if secs % 60 == 0:
        return "Every %d minutes" % (secs // 60)
    return "Every %d seconds" % secs


def launchd_job(path, now):
    """One plist -> a cron[] item (source launchd), or None when it is not ours / not scheduled / disabled."""
    with open(path, "rb") as f:
        d = plistlib.load(f)
    if not isinstance(d, dict) or d.get("Disabled") is True:
        return None
    label = d.get("Label") if isinstance(d.get("Label"), str) else os.path.basename(path)[:-len(".plist")]
    prefix = next((p for p in LAUNCHD_PREFIXES if label.startswith(p)), None)
    name = label[len(prefix):] if prefix else None
    if not name or not CRON_NAME_RE.match(name):
        return None
    interval = d.get("StartInterval")
    interval = interval if isinstance(interval, int) and not isinstance(interval, bool) and interval > 0 else None
    fields, schedule, human = None, None, None
    cal = d.get("StartCalendarInterval")
    if cal:
        fields = launchd_calendar(cal)
        if fields:
            schedule = " ".join(fields)
            human = _every_minutes_human(fields) or cron_human(fields)
            if len(schedule) > 60:
                fields, schedule, human = None, "@calendar", "Custom schedule"
        else:
            schedule, human = "@calendar", "Custom schedule"
    elif interval:
        schedule, human = "@every %ds" % interval, _interval_human(interval)
    elif d.get("KeepAlive"):
        schedule, human = "@keepalive", "Kept running"
    elif d.get("RunAtLoad") is True:
        schedule, human = "@reboot", "At login"
    else:
        return None  # launched by hand or on demand: nothing scheduled to show
    script = next((a for a in (d.get("ProgramArguments") or []) if isinstance(a, str) and resolve_script(a)), None)
    last_run, result = cron_last_run(name)
    if last_run is None:  # no ~/logs/<name>/: the plist's own log file still says when it last wrote (never the result)
        for key in ("StandardOutPath", "StandardErrorPath"):
            p = d.get(key)
            real = _under_home(p) if isinstance(p, str) and os.path.isabs(p) else None
            if real and os.path.isfile(real):
                last_run = _epoch_iso(os.stat(real).st_mtime)
                break
    next_run = None
    if fields:
        nxt = cron_next_run(parse_cron_schedule(fields), now)
        next_run = _epoch_iso(nxt) if nxt is not None else None
    elif interval and last_run:
        nxt = int(datetime.datetime.strptime(last_run, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()) + interval
        next_run = _epoch_iso(nxt) if nxt > now else None
    return _cron_item(name, schedule, human, last_run, result, next_run, script_description(script) if script else None, "launchd")


def build_launchd(now):
    d = _cron_dir("STATUS_LAUNCHD_DIR", os.path.join(os.path.expanduser("~"), "Library", "LaunchAgents"))
    if not d or not _is_darwin() or not os.path.isdir(d):
        return [], 0
    out, errors = [], 0
    for fname in sorted(os.listdir(d)):
        if not fname.endswith(".plist") or not fname.startswith(LAUNCHD_PREFIXES):
            continue
        try:
            item = launchd_job(os.path.join(d, fname), now)
        except Exception:
            errors += 1
            continue
        if item:
            out.append(item)
    return out, errors


# ---- Claude desktop scheduled tasks (macOS only): ~/.claude/scheduled-tasks/<name>/SKILL.md ----
# The schedule lives in the app and is not cheaply readable, so only the name and the frontmatter description are.
def skill_description(path):
    with open(path, "rb") as f:
        lines = f.read(CRON_LOG_TAIL_BYTES // 16).decode("utf-8", errors="replace").splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    for i, raw in enumerate(lines[1:], start=1):
        if raw.strip() == "---":
            return None
        m = re.match(r"^description\s*:\s*(.*)$", raw)
        if not m:
            continue
        val = m.group(1).strip()
        if val in ("", ">", "|", ">-", "|-") and i + 1 < len(lines):
            val = lines[i + 1].strip()
        if len(val) >= 2 and val[0] in "'\"" and val[-1] == val[0]:
            val = val[1:-1]
        return clean_description(val)
    return None


def build_desktop():
    d = _cron_dir("STATUS_DESKTOP_TASKS_DIR", os.path.join(os.path.expanduser("~"), ".claude", "scheduled-tasks"))
    if not d or not _is_darwin() or not os.path.isdir(d):
        return [], 0
    out, errors = [], 0
    for name in sorted(os.listdir(d)):
        skill = os.path.join(d, name, "SKILL.md")
        if not CRON_NAME_RE.match(name) or not os.path.isfile(skill):
            continue
        try:
            last_run, result = cron_last_run(name)
            out.append(_cron_item(name, "@app", "Set in the Claude app", last_run, result, None, skill_description(skill), "desktop"))
        except Exception:
            errors += 1
    return out, errors


def _cron_item(name, schedule, human, last_run, result, next_run, description, source):
    item = {"name": name, "schedule": schedule, "schedule_human": human,
            "last_run": last_run, "last_result": result, "next_run": next_run}
    description = curated_description(name, description)
    if description:
        item["description"] = description
    item["source"] = source
    return item


def build_cron(text):
    try:
        now = int(os.environ.get("STATUS_CRON_NOW") or time.time())  # STATUS_CRON_NOW: test hook only
    except ValueError:
        now = int(time.time())
    out, scan_errors = [], 0
    for job in parse_crontab(text):
        try:
            last_run, result = cron_last_run(job["stem"], job["arg"])
        except Exception:
            last_run, result, scan_errors = None, "unknown", scan_errors + 1
        next_run = None
        if job["fields"]:
            nxt = cron_next_run(parse_cron_schedule(job["fields"]), now)
            next_run = _epoch_iso(nxt) if nxt is not None else None
        try:
            description = script_description(job["script"])
        except Exception:
            description, scan_errors = None, scan_errors + 1
        out.append(_cron_item(job["name"], job["schedule"], job["human"], last_run, result, next_run, description, "cron"))
    # Mac only, each isolated: a plist or task directory that cannot be read costs its own entries, never the beat.
    for collect in (lambda: build_launchd(now), build_desktop):
        try:
            items, errors = collect()
        except Exception:
            items, errors = [], 1
        out.extend(items)
        scan_errors += errors
    if scan_errors:
        sys.stderr.write("scan_errors=%d\n" % scan_errors)  # a count only, never a path or content
    return out[:CRON_MAX]


if mode == "cron":
    print(json.dumps(build_cron(sys.stdin.read())))
    sys.exit(0)

GOALS_MAX = 50
GOALS_RECENT_MAX = 5
GOAL_STATES = ("active", "waiting_jp", "held")


def _pid_alive(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            pid = int(f.readline(32).strip())
        if pid <= 0:
            return False
        os.kill(pid, 0)
    except PermissionError:
        return True
    except (OSError, ValueError, OverflowError):
        return False
    return True


def _goal_url(issue):
    # the goal's registry issue on GitHub
    if isinstance(issue, int) and not isinstance(issue, bool) and issue > 0:
        return "https://github.com/%s/issues/%d" % (os.environ.get("GOAL_REGISTRY_REPO") or "jpmoya/claude-agents", issue)
    return None


def _goal_link(d):
    """Where a goal's name leads: its GitHub Project when one is recorded, else a GitHub search of every ticket of the goal across its repos (label goal), the
    milestone page (milestone goal), the ticket (ticket goal); else the registry issue."""
    label, repos, spec = d.get("label"), d.get("repos"), d.get("spec")
    proj = d.get("project_url")
    if not isinstance(proj, str) and isinstance(d.get("project"), dict):
        proj = d["project"].get("url")
    if isinstance(proj, str) and re.match(r"^https://github\.com/(users|orgs)/[\w.-]+/projects/\d+$", proj):
        return proj   # the goal's own GitHub Project (goal-project.sh); else the search / milestone / ticket link below
    if isinstance(label, str) and label and isinstance(repos, list) and repos and all(isinstance(r, str) and r for r in repos):
        q = 'is:issue label:"%s" ' % label.replace('"', "") + " ".join("repo:" + r for r in repos)
        return "https://github.com/issues?q=" + urllib.parse.quote(q, safe="")
    if isinstance(spec, str):
        m = re.match(r"^([\w.-]+/[\w.-]+):milestone:(\d+)$", spec)
        if m:
            return "https://github.com/%s/milestone/%s?closed=1" % (m.group(1), m.group(2))
        m = re.match(r"^([\w.-]+/[\w.-]+):milestones?:", spec)
        if m:
            return "https://github.com/%s/issues?q=%s" % (m.group(1), urllib.parse.quote("is:issue milestone:*", safe=""))
        m = re.match(r"^([\w.-]+/[\w.-]+)#(\d+)$", spec)
        if m:
            return "https://github.com/%s/issues/%s" % (m.group(1), m.group(2))
    return _goal_url(d.get("issue"))


def _host_key(h):
    """The status page keys hosts mac|vm; the registry and the goal cache hold the hostname (hostname -s, lower-case).
    This machine's hostname maps to its own kind; the only other host is the opposite kind."""
    if not isinstance(h, str) or not h:
        return ""
    h = h.lower()
    if h in ("mac", "vm"):
        return h
    mine = "mac" if sys.platform == "darwin" else "vm"
    if h == socket.gethostname().split(".")[0].lower():
        return mine
    return "vm" if mine == "mac" else "mac"


def _fill_name(entry):
    """A goal whose block has no title (a milestone / ticket goal) gets the name the sync looked up (goalnames.json)."""
    if entry.get("title") or not pipe_dir:
        return
    try:
        with open(os.path.join(pipe_dir, "goalnames.json"), encoding="utf-8") as f:
            names = json.load(f)
        name = names.get(entry["id"]) if isinstance(names, dict) else None
    except (OSError, ValueError):
        return
    if isinstance(name, str) and name:
        entry["title"] = name


def _set_priority(entry, d):
    p = d.get("priority")
    if isinstance(p, int) and not isinstance(p, bool) and p > 0:
        entry["priority"] = p


def build_goals():
    if not pipe_dir:
        return []
    try:
        names = sorted(n for n in os.listdir(pipe_dir) if n.startswith("goal-") and n.endswith(".json"))
    except OSError:
        return []
    out = []
    # Registry priorities (goalqueue.json, rewritten from the registry every sync): they win over a local cache's copy, which
    # only the host that ran `deliver.sh priority` refreshed, so two hosts no longer report one goal at two priorities.
    reg_prio = {}
    try:
        with open(os.path.join(pipe_dir, "goalqueue.json"), encoding="utf-8") as f:
            gq = json.load(f)
        for k in ("open", "queued", "recent"):
            for d in (gq.get(k) or []) if isinstance(gq, dict) else []:
                if isinstance(d, dict) and isinstance(d.get("id"), str):
                    pr = d.get("priority")
                    if isinstance(pr, int) and not isinstance(pr, bool) and pr > 0 and d["id"] not in reg_prio:
                        reg_prio[d["id"]] = pr
    except (OSError, ValueError, AttributeError, TypeError):
        reg_prio = {}
    for name in names:
        stem = name[:-5]
        base = os.path.join(pipe_dir, stem)
        try:
            with open(base + ".json", encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(d, dict):
            continue
        # v1 goals carry `spec`; a cross-repo label goal (#319) carries title/repos/order and may have no spec
        if not all(isinstance(d.get(k), str) and d.get(k) for k in ("id", "host")):
            continue
        if not (isinstance(d.get("spec"), str) and d.get("spec")) and not (isinstance(d.get("title"), str) and d.get("title")):
            continue
        if os.path.exists(base + ".stopped"):
            continue
        held_file = os.path.exists(base + ".held")
        raw_state = d.get("state")
        if raw_state is None:
            raw_state = "held" if held_file else "active"
        if raw_state not in GOAL_STATES:
            continue
        if held_file or raw_state == "held":
            state = "held"
        elif raw_state == "waiting_jp":
            state = "waiting_jp"
        else:
            state = "running" if _pid_alive(base + ".pid") else "between_cycles"
        entry = {"id": d["id"]}
        if isinstance(d.get("spec"), str) and d.get("spec"):
            entry["spec"] = d["spec"]
        entry["host"] = _host_key(d["host"])
        entry["state"] = state
        if isinstance(d.get("title"), str) and d.get("title"):
            entry["title"] = d["title"]
        repos = d.get("repos")
        if isinstance(repos, list) and repos and all(isinstance(r, str) and r for r in repos):
            entry["repos"] = repos
        if isinstance(d.get("order"), int) and not isinstance(d.get("order"), bool):
            entry["order"] = d["order"]
        for k in ("scope_total", "scope_delivered"):
            v = d.get(k)
            if isinstance(v, int) and not isinstance(v, bool):
                entry[k] = v
        if isinstance(d.get("last_cycle_at"), str) and ISO_Z_RE.match(d["last_cycle_at"]):
            entry["last_cycle_at"] = d["last_cycle_at"]
        if _goal_link(d):
            entry["url"] = _goal_link(d)
        _set_priority(entry, d)
        if d["id"] in reg_prio:
            entry["priority"] = reg_prio[d["id"]]
        _fill_name(entry)
        out.append(entry)
        if len(out) >= GOALS_MAX:
            break
    # queued goals (#320): the supervisor's sync writes goalqueue.json (queued goals in queue order); a goal that has a
    # local cache is already started here and is reported above. `paused` is the one reason the head of the queue waits.
    q = None
    try:
        with open(os.path.join(pipe_dir, "goalqueue.json"), encoding="utf-8") as f:
            q = json.load(f)
        queued = q.get("queued") if isinstance(q, dict) else None
    except (OSError, ValueError):
        queued = None
    paused = ""
    try:
        with open(os.path.join(pipe_dir, "goal-paused"), encoding="utf-8") as f:
            paused = f.readline(64).strip()
    except OSError:
        pass
    if isinstance(queued, list):
        started = set(e["id"] for e in out)
        pos = 0
        for d in queued:
            if len(out) >= GOALS_MAX:
                break
            if not isinstance(d, dict) or not (isinstance(d.get("id"), str) and d.get("id")):
                continue
            pos += 1
            if d["id"] in started or os.path.exists(os.path.join(pipe_dir, "goal-" + d["id"] + ".json")):
                continue
            entry = {"id": d["id"]}
            if isinstance(d.get("spec"), str) and d.get("spec"):
                entry["spec"] = d["spec"]
            entry["host"] = ""
            entry["state"] = "queued"
            entry["queue_pos"] = pos
            if isinstance(d.get("title"), str) and d.get("title"):
                entry["title"] = d["title"]
            repos = d.get("repos")
            if isinstance(repos, list) and repos and all(isinstance(r, str) and r for r in repos):
                entry["repos"] = repos
            if isinstance(d.get("order"), int) and not isinstance(d.get("order"), bool):
                entry["order"] = d["order"]
            if pos == 1 and paused:
                entry["paused"] = paused
            if _goal_link(d):
                entry["url"] = _goal_link(d)
            _set_priority(entry, d)
            _fill_name(entry)
            out.append(entry)
    # every other registered, not-yet-reported goal that is still open (e.g. pinned to a host that is offline)
    opened = q.get("open") if isinstance(q, dict) else None
    if isinstance(opened, list):
        known = set(e["id"] for e in out)
        for d in opened:
            if len(out) >= GOALS_MAX:
                break
            if not isinstance(d, dict) or not (isinstance(d.get("id"), str) and d.get("id")) or d["id"] in known:
                continue
            st = {"held": "held", "waiting_jp": "waiting_jp", "active": "between_cycles"}.get(d.get("st"))
            # ticket evidence (supervisor goal_queue_derive): nothing progressable and something waits on JP
            nj = d.get("needs_jp")
            if st == "between_cycles" and isinstance(nj, dict) and nj.get("active") == 0 \
                    and isinstance(nj.get("waiting"), int) and nj["waiting"] > 0:
                st = "waiting_jp"
            if st is None or not (isinstance(d.get("title"), str) and d["title"]) and not (isinstance(d.get("spec"), str) and d["spec"]):
                continue
            entry = {"id": d["id"]}
            if isinstance(d.get("spec"), str) and d.get("spec"):
                entry["spec"] = d["spec"]
            entry["host"] = _host_key(d.get("host"))
            entry["state"] = st
            if isinstance(d.get("title"), str) and d.get("title"):
                entry["title"] = d["title"]
            repos = d.get("repos")
            if isinstance(repos, list) and repos and all(isinstance(r, str) and r for r in repos):
                entry["repos"] = repos
            if _goal_link(d):
                entry["url"] = _goal_link(d)
            _set_priority(entry, d)
            _fill_name(entry)
            out.append(entry)
    # recently closed goals (delivered / stopped, newest first, max 5): the status page lists them compactly
    recent = q.get("recent") if isinstance(q, dict) else None
    if isinstance(recent, list):
        known = set(e["id"] for e in out)
        n = 0
        for d in recent:
            if n >= GOALS_RECENT_MAX or len(out) >= GOALS_MAX:
                break
            if not isinstance(d, dict) or not (isinstance(d.get("id"), str) and d.get("id")):
                continue
            if d.get("st") not in ("delivered", "stopped") or d["id"] in known:
                continue
            if os.path.exists(os.path.join(pipe_dir, "goal-" + d["id"] + ".json")):
                continue
            if not (isinstance(d.get("title"), str) and d["title"]) and not (isinstance(d.get("spec"), str) and d["spec"]):
                continue
            entry = {"id": d["id"]}
            if isinstance(d.get("spec"), str) and d.get("spec"):
                entry["spec"] = d["spec"]
            entry["host"] = ""
            entry["state"] = d["st"]
            if isinstance(d.get("title"), str) and d.get("title"):
                entry["title"] = d["title"]
            repos = d.get("repos")
            if isinstance(repos, list) and repos and all(isinstance(r, str) and r for r in repos):
                entry["repos"] = repos
            if isinstance(d.get("closed_at"), str) and ISO_Z_RE.match(d["closed_at"]):
                entry["closed_at"] = d["closed_at"]
            if _goal_link(d):
                entry["url"] = _goal_link(d)
            _set_priority(entry, d)
            _fill_name(entry)
            out.append(entry)
            n += 1
    # The registry is the one source of truth (JP, 2026-11-18): the list is exactly the registered goals (open, queued, recently closed),
    # each under its registry name. A GitHub Project is never a row of its own (an unregistered "Goal: ..." project used to show as a
    # queued goal that never started, #697); a project only supplies the link of the goal it is bound to. Milestone goals are
    # registered goals too and show like any other.
    reg_name, reg_ids = _registry_names(q)
    if reg_ids is not None:
        out = [e for e in out if e["id"] in reg_ids]   # a leftover local cache of a goal the registry no longer lists is not a goal
    for e in out:
        if e["id"] in reg_name:
            e["title"] = reg_name[e["id"]]
    # Where each goal stands on the one goal slot (GOAL_SERIAL=1; the sync writes `slot` = the holder's id and `exempt` = the slot-exempt goals,
    # i.e. the feedback goals, into goalqueue.json from the same registry read goal-lib's slot logic uses): "holds" on the holder (its host is the
    # row's host), "alongside" on an exempt goal, "waits" on a queued one. Nothing when the queue file does not say it is serial.
    if isinstance(q, dict) and q.get("serial") is True:
        holder = q.get("slot") if isinstance(q.get("slot"), str) else None
        exempt = set(x for x in (q.get("exempt") or []) if isinstance(x, str)) if isinstance(q.get("exempt"), list) else set()
        for e in out:
            if e.get("state") in ("delivered", "stopped"):
                continue
            if e["id"] in exempt:
                e["slot"] = "alongside"
            elif holder and e["id"] == holder:
                e["slot"] = "holds"
            elif e.get("state") == "queued":
                e["slot"] = "waits"
    return out


def _registry_names(q):
    """From goalqueue.json (the supervisor sync's copy of the registry): ({goal id: registry name}, set of every registered goal id the file
    lists), or ({}, None) when the file is missing or unreadable (a host that never synced keeps its local goal rows as they are).
    The name is the registry's own (`name`, the registry issue title without its "Goal: " prefix); the sync leaves it empty when the issue
    title only repeats the spec, and the block's title is the name then."""
    if not isinstance(q, dict) or not isinstance(q.get("open"), list):
        return {}, None
    names, ids = {}, set()
    for k in ("open", "queued", "recent"):
        for d in q.get(k) or []:
            if not isinstance(d, dict) or not (isinstance(d.get("id"), str) and d["id"]):
                continue
            ids.add(d["id"])
            nm = d.get("name")
            if isinstance(nm, str) and nm.strip():
                names[d["id"]] = nm.strip()
    return names, ids


GOAL_STALL_ERR_SECS = 900          # a project-scope error older than this has stopped repeating (the sync runs every GOAL_SYNC_SECS=300)
GOAL_STALL_TAIL_BYTES = 262144     # events.jsonl is megabytes: only its tail is read
GOAL_STALL_MAX = 5
GOAL_STALL_BLOCKED_MAX = 10
_STALL_TEXT_UNSAFE = re.compile(r"[^A-Za-z0-9 .,:;/_()#'\-]")
_PROJ_ERR_RE = re.compile(r"^project goal ([A-Za-z0-9_.-]+)/([0-9]+): (?:cannot read the project scope: )?(.*)$")


def _stall_text(value, cap):
    """Plain text only: unsafe characters become spaces, whitespace collapses, capped. Repo slugs, ids and gh's redacted first line pass."""
    return re.sub(r"\s+", " ", _STALL_TEXT_UNSAFE.sub(" ", str(value))).strip()[:cap]


def _stall_hint(reason):
    r = reason.lower()
    if "is closed" in r:
        return "reopen the project, or stop the goal bound to it (deliver.sh stop)"
    if "does not exist" in r or "cannot read it" in r:
        return "check the project still exists and this host's gh token can read it, or stop the goal (deliver.sh stop)"
    if "token" in r and "scope" in r:
        return "run gh auth refresh -s project on the host that reports this"
    if "overlap" in r:
        return "two goals cover the same tickets: stop one of them (deliver.sh status)"
    return "see the [goal] error lines in the supervisor log, then fix or stop the goal"


def _recent_project_errors(now_epoch):
    """{owner/number: reason} newest per project from the tail of events.jsonl, error events on route goal-project-scope younger than the window."""
    path = os.environ.get("STATUS_EVENTS_FILE") or os.path.expanduser("~/logs/pipeline/events.jsonl")
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - GOAL_STALL_TAIL_BYTES))
            raw = f.read().decode("utf-8", errors="replace")
    except OSError:
        return {}
    out = {}
    for line in raw.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict) or ev.get("event") != "error" or ev.get("route") != "goal-project-scope":
            continue
        ts = ev.get("ts")
        if not (isinstance(ts, str) and ISO_Z_RE.match(ts)):
            continue
        try:
            age = now_epoch - datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
        except ValueError:
            continue
        m = _PROJ_ERR_RE.match(ev.get("message") if isinstance(ev.get("message"), str) else "")
        if m and -60 <= age <= GOAL_STALL_ERR_SECS:
            out["%s/%s" % (m.group(1), m.group(2))] = m.group(3)   # later lines overwrite: newest wins
    return out


def build_goal_stall():
    """Why goals wait in the queue and nothing starts: an unreadable registry entry (it blocks every queued goal while GOAL_SERIAL=1) or a project
    goal whose scope cannot be read (closed project, missing token scope). Nothing when no goal is queued (nothing is blocked)."""
    if not pipe_dir:
        return []
    try:
        with open(os.path.join(pipe_dir, "goalqueue.json"), encoding="utf-8") as f:
            q = json.load(f)
    except (OSError, ValueError):
        return []
    if not isinstance(q, dict) or q.get("serial") is not True or not isinstance(q.get("queued"), list):
        return []
    goals = build_goals()
    name_of = {}
    for e in goals:
        name_of[e["id"]] = (e.get("title") or e.get("spec") or e["id"])
    queued = [d["id"] for d in q["queued"] if isinstance(d, dict) and isinstance(d.get("id"), str) and d["id"]]
    if not queued:
        return []
    out = []

    def blocked_for(own_id):
        names = [_stall_text(name_of.get(i) or i, 80) for i in queued if i != own_id]
        return [n for n in names if n][:GOAL_STALL_BLOCKED_MAX]

    for d in q.get("unreadable") or []:
        if isinstance(d, dict) and isinstance(d.get("issue"), int) and not isinstance(d.get("issue"), bool):
            out.append({"kind": "unreadable", "goal": "registry issue #%d" % d["issue"],
                        "reason": "its goal block cannot be read, so no queued goal may start",
                        "hint": "fix or close registry issue #%d" % d["issue"], "blocked": blocked_for(None)})
    for ref, why in sorted(_recent_project_errors(time.time()).items()):
        gid = "proj-%s_%s" % tuple(ref.split("/", 1))
        reason = _stall_text(why, 120) or "the project cannot be read"
        out.append({"kind": "project_error", "goal": _stall_text(name_of.get(gid) or "project " + ref, 80),
                    "reason": reason, "hint": _stall_hint(reason), "blocked": blocked_for(gid)})
    return [x for x in out if x["blocked"]][:GOAL_STALL_MAX]


if mode == "goalstall":
    print(json.dumps(build_goal_stall()))
    sys.exit(0)

if mode == "goals":
    print(json.dumps(build_goals()))
    sys.exit(0)

# A non-running row whose ticket is already on this host's staging list is not "in flight" (#65).
staged = set((d["owner_repo"], d["issue"]) for d in load_list("staging"))

runs = []
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    while len(parts) < 8:
        parts.append("")
    issue, repo_path, state_code, pid, started_at, last_activity_epoch, restarts, stage = parts[:8]
    if state_code not in STATE_MAP:
        continue
    CUR_REPO = repo_path
    repo_alias, owner_repo = alias_for(repo_path)
    if state_code != "running" and issue.isdigit() and (owner_repo, int(issue)) in staged:
        continue
    run = {
        "repo": repo_alias,
        "issue": int(issue) if issue.isdigit() else issue,
        "state": STATE_MAP[state_code],
        "stage": stage or None,
        "marker": marker_for(owner_repo, issue),
        "started_at": started_at or None,
        "last_activity_at": iso(last_activity_epoch) or (started_at or None),
        "restarts": int(restarts) if str(restarts).lstrip("-").isdigit() else 0,
    }
    run = {k: v for k, v in run.items() if v is not None}
    # Published on the public page by JP's decision (#29): the title, and the issue URL -- the only
    # place owner/repo may appear in the payload. No title file -> neither field.
    title = title_for(issue)
    if title:
        run["title"] = title
        if owner_repo and issue.isdigit():
            run["url"] = "https://github.com/%s/issues/%s" % (owner_repo, issue)
    milestone = milestone_for(issue)
    if milestone:
        run["milestone"] = milestone
    # Issue #139: fixed labels / enum / timestamp only, never comment text (re-checked here).
    needs = state_file_for(issue, "needs")
    if needs in NEEDS_LABELS:
        run["needs"] = needs
    gate_at = state_file_for(issue, "gate_at")
    if ISO_Z_RE.match(gate_at):
        run["gate_at"] = gate_at
    parked_reason = state_file_for(issue, "parked_reason")
    if parked_reason in PARKED_REASONS:
        run["parked_reason"] = parked_reason
    block_class = state_file_for(issue, "block_class")
    if parked_reason == "auto_retry" and BLOCK_CLASS_RE.match(block_class):
        run["block_class"] = block_class
    activity_epoch = int(last_activity_epoch) if last_activity_epoch.strip().isdigit() else -1
    sort_key = (STATE_PRIORITY[state_code], -activity_epoch)
    runs.append((sort_key, run))

runs.sort(key=lambda pair: pair[0])
print(json.dumps([run for _, run in runs[:20]]))
