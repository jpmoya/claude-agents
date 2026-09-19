#!/usr/bin/env python3
# Turns derive_runs()'s TSV (issue, repo_path, state_code, pid, started_at, last_activity_at_epoch,
# restarts, stage) on stdin into the v1 payload's "runs" JSON array. Called by report-status.sh —
# a standalone file (not a heredoc) so stdin stays free to carry the TSV data.
#
# Usage: build-runs-json.py <aliases-arg> <runs-jsonl-path> [<pipe-dir>]
#   <aliases-arg>: STATUS_REPO_ALIASES entries ("owner/repo:alias"), one per line
#   <runs-jsonl-path>: ~/.claude/pipeline/runs.jsonl, for the last dispatch marker per repo+issue
#   <pipe-dir>: $PIPE, for the per-run orch-<issue>.title file written at launch (issue #29).
#               Local files only -- this script never makes a network call.
import sys
import json
import subprocess
import os
import datetime

aliases_raw, runs_jsonl = sys.argv[1], sys.argv[2]
pipe_dir = sys.argv[3] if len(sys.argv) > 3 else ""

TITLE_MAX_CHARS = 140

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


def marker_for(owner_repo, issue):  # last dispatch event's marker_after for this repo+issue, else None
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
STATE_PRIORITY = {"running": 0, "restarting": 1, "held": 2, "queued": 3}

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
