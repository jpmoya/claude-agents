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
import sys
import json
import subprocess
import os
import re
import datetime
import urllib.parse

aliases_raw, runs_jsonl = sys.argv[1], sys.argv[2]
pipe_dir = sys.argv[3] if len(sys.argv) > 3 else ""
mode = sys.argv[4] if len(sys.argv) > 4 else ""
completed_mode = mode == "completed"
LIST_CAPS = {"staging": 60, "approved": 20}
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
    return items[:LIST_CAPS[kind]]


NEEDS_LABELS = ("Approve mockups", "Say go", "Approve effort", "Missing credential", "Decision needed")
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
    """Where a goal's name leads: a GitHub search of every ticket of the goal across its repos (label goal), the
    milestone page (milestone goal), the ticket (ticket goal); else the registry issue."""
    label, repos, spec = d.get("label"), d.get("repos"), d.get("spec")
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


def build_goals():
    if not pipe_dir:
        return []
    try:
        names = sorted(n for n in os.listdir(pipe_dir) if n.startswith("goal-") and n.endswith(".json"))
    except OSError:
        return []
    out = []
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
        entry["host"] = d["host"]
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
            out.append(entry)
            n += 1
    return out


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
