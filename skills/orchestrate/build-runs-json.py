#!/usr/bin/env python3
# Turns derive_runs()'s TSV (issue, repo_path, state_code, pid, started_at, last_activity_at_epoch,
# restarts, stage) on stdin into the v1 payload's "runs" JSON array. Called by report-status.sh —
# a standalone file (not a heredoc) so stdin stays free to carry the TSV data.
#
# Usage: build-runs-json.py <aliases-arg> <runs-jsonl-path> [<pipe-dir> [completed]]
#   <aliases-arg>: STATUS_REPO_ALIASES entries ("owner/repo:alias"), one per line
#   <runs-jsonl-path>: ~/.claude/pipeline/runs.jsonl, for the last dispatch marker per repo+issue
#   <pipe-dir>: $PIPE, for the per-run orch-<issue>.title file written at launch (issue #29).
#               Local files only -- this script never makes a network call.
#   completed:  emit the payload's "completed" array (issue #51) instead of "runs": the records
#               reconcile-status.sh marked closed (state_code "closed", orch-<issue>.closed = closedAt),
#               closed within the last 7 days, newest first, first 10. Items carry "release" when
#               orch-<issue>.release exists (issue #65).
#   staging | approved: emit the payload's "staging" / "approved" array (issue #65) from
#               <pipe-dir>/status-staging.json / status-approved.json (written by reconcile-status.sh);
#               no stdin, `[]` when the file is missing or unreadable.
import sys
import json
import subprocess
import os
import re
import datetime

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


_marker_cache = {}


def marker_file_for(issue):  # first line of <pipe-dir>/orch-<issue>.marker (GitHub truth, written by reconcile-status.sh), else ""
    if not pipe_dir:
        return ""
    try:
        with open(os.path.join(pipe_dir, "orch-%s.marker" % issue), encoding="utf-8", errors="replace") as f:
            return f.readline(256).strip()
    except OSError:
        return ""


def marker_for(owner_repo, issue):  # orch-<issue>.marker if present, else last dispatch event's marker_after for this repo+issue, else None
    from_file = marker_file_for(issue)
    if from_file:
        return from_file
    if not owner_repo:
        return None
    key = (owner_repo, str(issue))
    if key in _marker_cache:
        return _marker_cache[key]
    marker = None
    if os.path.isfile(runs_jsonl):
        try:
            with open(runs_jsonl) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    if d.get("event") != "dispatch":
                        continue
                    if d.get("repo") != owner_repo:
                        continue
                    if str(d.get("issue")) != str(issue):
                        continue
                    marker_after = d.get("marker_after")
                    if marker_after:
                        marker = marker_after
        except OSError:
            pass
    _marker_cache[key] = marker
    return marker


def title_for(issue):  # first line of <pipe-dir>/orch-<issue>.title, stripped + capped; else ""
    if not pipe_dir:
        return ""
    try:
        with open(os.path.join(pipe_dir, "orch-%s.title" % issue), encoding="utf-8", errors="replace") as f:
            first_line = f.readline(4096)
    except OSError:
        return ""
    return first_line.strip()[:TITLE_MAX_CHARS]


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


def release_for(issue):  # first line of <pipe-dir>/orch-<issue>.release if it is vX.Y.Z, else ""
    if not pipe_dir:
        return ""
    try:
        with open(os.path.join(pipe_dir, "orch-%s.release" % issue), encoding="utf-8", errors="replace") as f:
            text = f.readline(64).strip()
    except OSError:
        return ""
    return text if RELEASE_RE.match(text) else ""


def closed_at_for(issue):  # first line of <pipe-dir>/orch-<issue>.closed -> (iso string, epoch) or None
    if not pipe_dir:
        return None
    try:
        with open(os.path.join(pipe_dir, "orch-%s.closed" % issue), encoding="utf-8", errors="replace") as f:
            text = f.readline(64).strip()
        epoch = datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except (OSError, ValueError):
        return None
    return text, epoch


def build_completed(rows):
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    items = []
    for line in rows:
        parts = line.split("\t")
        while len(parts) < 8:
            parts.append("")
        issue, repo_path, state_code = parts[0], parts[1], parts[2]
        if state_code != "closed":
            continue
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
    activity_epoch = int(last_activity_epoch) if last_activity_epoch.strip().isdigit() else -1
    sort_key = (STATE_PRIORITY[state_code], -activity_epoch)
    runs.append((sort_key, run))

runs.sort(key=lambda pair: pair[0])
print(json.dumps([run for _, run in runs[:20]]))
