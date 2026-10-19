#!/usr/bin/env python3
"""Host drift check + safe auto-fixes (docs/host-sync.md). Runs daily on the Mac and the Clog VM.

  host-drift.py [--fix] [--alert] [--manifest PATH] [--json]

Compares THIS host against infra/host-manifest.json (names, paths, version floors; never secret values).
Prints nothing and exits 0 when the host is clean. With --fix it applies only the safe, local, reversible fixes
(listed in FIXES below). With --alert it opens/updates ONE GitHub issue per host ("Host drift: <host>") only when
the set of drift items CHANGED since the last run, and closes it when the host is clean again.
It never deletes anything, never prints or stores secret values, never touches application code.
"""
import argparse, glob, hashlib, json, os, re, shutil, stat, subprocess, sys, time

HOME = os.path.expanduser("~")
HOST = os.environ.get("HOST_ID") or ("mac" if sys.platform == "darwin" else "vm")
PIPE_CFG = os.path.join(HOME, ".claude", "pipeline")
ALERT_REPO = "jpmoya/claude-agents"
F, I, P, D = [], [], [], []          # fixed, info, pending-decisions, drift (list of dicts)


def run(cmd, timeout=30, env=None, shell=False):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, shell=shell)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:  # missing binary, timeout
        return 127, str(e)


def x(p):
    return os.path.expanduser(p) if p else p


def drift(cid, msg, hint=None):
    D.append({"id": cid, "msg": msg, "hint": hint})


def vtuple(s):
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", s or "")
    return tuple(int(g) for g in m.groups()) if m else (0, 0, 0)


def find_repo_root():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(here)


# ---------------------------------------------------------------- checks
def pipeline_env():
    """Environment as the supervisor sees it: PATH after config.sh (this is what headless agents run with)."""
    cfg = os.path.join(HOME, ".claude", "skills", "orchestrate", "config.sh")
    if not os.path.exists(cfg):
        cfg = os.path.join(find_repo_root(), "skills", "orchestrate", "config.sh")
    rc, out = run(["bash", "-c", f'source "{cfg}" >/dev/null 2>&1; printf %s "$PATH"'])
    env = dict(os.environ)
    if rc == 0 and out:
        env["PATH"] = out
    return env


def check_symlinks(repo):
    for item in ("agents", "hooks", "skills", "CLAUDE.md", "settings.json"):
        link = os.path.join(HOME, ".claude", item)
        want = os.path.join(repo, item)
        if not (os.path.islink(link) and os.path.realpath(link) == os.path.realpath(want)):
            drift("symlink:" + item, f"~/.claude/{item} is not a symlink to {want}", "run skills/orchestrate/install.sh")


def check_code(repo, fix):
    """Main checkout must be on main and at origin/main (the supervisor executes whatever is checked out there)."""
    sync = os.path.join(repo, "skills", "orchestrate", "code-sync.sh")
    verdict = (run(["bash", sync, "check"], timeout=90)[1].strip().splitlines() or ["?"])[-1]
    if verdict == "fixable" and fix:
        if run(["bash", sync, "apply"], timeout=60)[0] == 0:
            F.append("claude-agents main checkout switched to main / fast-forwarded to origin/main"); return
        verdict = "stale"
    if verdict in ("fixable", "stale"):
        drift("code:" + verdict, "claude-agents checkout is behind origin/main or off main"
              + (" and cannot be fixed safely (uncommitted tracked edits or unpushed commits); the supervisor refuses to launch" if verdict == "stale" else ""),
              "work in a worktree under .worktrees/, then git -C %s checkout main && git pull --ff-only" % repo)


def check_tools(man, env):
    t = man["tools"]
    rc, out = run(["bash", "-c", "node -v"], env=env)
    major = int(re.search(r"v(\d+)", out).group(1)) if rc == 0 and re.search(r"v(\d+)", out) else None
    if major != t["node_major"]:
        drift("tool:node", f"node under the pipeline PATH is {out.strip() or 'missing'}, pinned major is {t['node_major']}",
              "mac: brew install node@%d (config.sh then prefers it); vm: install node %d" % (t["node_major"], t["node_major"]))
    # claude: every binary on PATH; the FIRST must be the newest, and above the floor
    seen, ver = [], {}
    for d in env["PATH"].split(":"):
        p = os.path.join(d, "claude")
        if os.path.isfile(p) and os.access(p, os.X_OK) and os.path.realpath(p) not in [os.path.realpath(s) for s in seen]:
            seen.append(p)
            ver[p] = vtuple(run([p, "--version"], env=env)[1])
    if not seen:
        drift("tool:claude", "claude not found on the pipeline PATH")
    else:
        newest = max(ver.values())
        if ver[seen[0]] < newest:
            drift("tool:claude-order", f"first claude on PATH ({seen[0]}) is older than another on PATH", "put ~/.local/bin first")
        if ver[seen[0]] < vtuple(t["min"]["claude"]):
            drift("tool:claude-min", f"claude {'.'.join(map(str, ver[seen[0]]))} is below the floor {t['min']['claude']}", "claude update")
        stale = [s for s in seen[1:] if ver[s] < newest]
        if stale:
            I.append("older claude binaries also on PATH (harmless while not first): " + ", ".join(stale))
    for tool, flag in (("gh", "--version"), ("wrangler", "--version")):
        rc, out = run([tool, flag], env=env)
        have = vtuple(out) if rc == 0 else None
        if tool == "wrangler" and rc != 0:
            rc, out = run(["bash", "-c", "command -v cf-wrangler >/dev/null && cf-wrangler --version"], env=env); have = vtuple(out) if rc == 0 else None
        if have is None:
            drift("tool:" + tool, f"{tool} missing")
        elif have < vtuple(t["min"][tool]):
            drift("tool:" + tool, f"{tool} {'.'.join(map(str, have))} below floor {t['min'][tool]}")
    if HOST == "vm":  # what `ssh clog-exec claude` resolves to (non-interactive bash reads ~/.bashrc)
        rc, out = run(["env", "-i", f"HOME={HOME}", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                       "bash", "-c", ". ~/.bashrc; command -v claude"])
        got = out.strip().splitlines()[-1] if out.strip() else ""
        if os.path.realpath(got) != os.path.realpath(os.path.join(HOME, ".local/bin/claude")):
            drift("path:vm-noninteractive", f"non-interactive ssh resolves claude to {got or 'nothing'} (stale system binary)", "fix: --fix adds ~/.local/bin to the top of ~/.bashrc")


def fix_vm_path():
    rc = os.path.join(HOME, ".bashrc")
    marker = "# >>> host-sync PATH (claude-agents bin/host-drift.py) >>>"
    block = marker + '\nexport PATH="$HOME/.local/bin:$PATH"\n# <<< host-sync PATH <<<\n'
    try:
        s = open(rc).read() if os.path.exists(rc) else ""
        if marker in s:
            return False
        shutil.copy(rc, rc + ".pre-host-sync") if os.path.exists(rc) and not os.path.exists(rc + ".pre-host-sync") else None
        open(rc, "w").write(block + s)
        return True
    except OSError:
        return False


def config_values():
    cfg = os.path.join(HOME, ".claude", "skills", "orchestrate", "config.sh")
    if not os.path.exists(cfg):
        cfg = os.path.join(find_repo_root(), "skills", "orchestrate", "config.sh")
    rc, out = run(["bash", "-c", f'source "{cfg}" >/dev/null 2>&1; echo "MAX_CONCURRENT=${{MAX_CONCURRENT:-}}"; '
                   'for k in DISPATCH_REPOS STATUS_PUSH_URL STATUS_PUSH_TOKEN; do [ -n "${!k:-}" ] && echo "HAS_$k=1" || echo "HAS_$k=0"; done'])
    vals = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
    lp = os.path.join(PIPE_CFG, "config.local.sh")
    if os.path.exists(lp):
        m = re.findall(r"^MAX_PUSHES_PER_DAY=(\d+)", open(lp).read(), re.M)
        if m:
            vals["MAX_PUSHES_PER_DAY"] = m[-1]
    return vals


def check_config(man):
    v = config_values()
    exp = man["per_host_config"][HOST]
    for k, want in exp.items():
        if v.get(k) != want:
            drift("config:" + k, f"{k} is {v.get(k) or 'unset'}, manifest says {want} for this host (deliberate per-host value; update the manifest if you changed it on purpose)")
    for k in man["config_local_required_keys"]:
        if v.get("HAS_" + k) != "1":
            drift("config:" + k, f"{k} is not set in config.local.sh")
    total = man["per_host_config"]["push_budget_total"]
    s = sum(int(man["per_host_config"][h]["MAX_PUSHES_PER_DAY"]) for h in ("mac", "vm"))
    if s > total:
        drift("config:push-budget", f"MAX_PUSHES_PER_DAY across hosts sums to {s}, over the {total}/day status-page cap")


def check_supervisor():
    if HOST == "mac":
        rc, out = run(["launchctl", "list"])
        if "com.jp.pipeline-supervisor" not in out:
            drift("sched:supervisor", "launchd job com.jp.pipeline-supervisor is not loaded")
    else:
        rc, out = run(["crontab", "-l"])
        if not re.search(r"^\s*[^#\s].*supervisor\.sh", out, re.M):
            drift("sched:supervisor", "no active cron line for supervisor.sh")


def git(repo, *a):
    return run(["git", "-C", repo] + list(a))


def check_repos(man, fix):
    for r in man["repos"]:
        path = x(r.get(HOST))
        if not path:
            continue
        required = HOST in r.get("required", [])
        if not os.path.isdir(os.path.join(path, ".git")):
            if os.path.isdir(path) and r.get("non_git"):
                continue
            if HOST in r.get("auto_clone", []) and r.get("github") and fix:
                rc, out = run(["gh", "repo", "clone", r["github"], path], timeout=300)
                if rc == 0:
                    F.append(f"cloned {r['github']} to {path}"); continue
            if required:
                drift("repo:" + r["name"], f"required clone missing at {path}", f"gh repo clone {r['github']} {path}" if r.get("github") else None)
            elif HOST in r.get("optional", []):
                I.append(f"optional clone not present: {r['name']}")
            continue
        # hooks
        if r.get("hooks") == "auto":
            _, hp = git(path, "config", "--local", "core.hooksPath"); hp = hp.strip()
            has = os.path.isdir(os.path.join(path, ".githooks"))
            cur_ok = bool(hp) and os.path.isdir(hp if os.path.isabs(hp) else os.path.join(path, hp))
            want = ".githooks" if has else None
            if (hp and not cur_ok) or (want and hp != want) or (not want and hp and hp.startswith("/")):
                msg = f"{r['name']}: core.hooksPath is {hp or 'unset'}" + (f", repo has .githooks" if has else ", repo has no .githooks")
                if fix:
                    if want:
                        git(path, "config", "--local", "core.hooksPath", want)
                    else:
                        git(path, "config", "--local", "--unset", "core.hooksPath")
                    F.append(msg + f" -> {want or 'unset'}")
                else:
                    drift("hooks:" + r["name"], msg, "run with --fix")
            elif want and not hp:
                if fix:
                    git(path, "config", "--local", "core.hooksPath", want); F.append(f"{r['name']}: core.hooksPath set to .githooks")
                else:
                    drift("hooks:" + r["name"], f"{r['name']}: core.hooksPath unset but repo has .githooks", "run with --fix")
        # env files (presence only)
        for rel in (r.get("env") or {}).get(HOST, []):
            if not os.path.isfile(os.path.join(path, rel)):
                drift(f"env:{r['name']}:{rel}", f"{r['name']}: required env file {rel} is missing (presence check only; values never read)",
                      "copy from the other host: bin/vm-sync.sh creds, or create it by hand")
        # info: state + stale env backups
        _, br = git(path, "branch", "--show-current")
        _, st = git(path, "status", "--porcelain")
        dirty = len([l for l in st.splitlines() if l.strip()])
        baks = [os.path.relpath(p, path) for p in glob.glob(os.path.join(path, "**", ".env*bak*"), recursive=True) if "node_modules" not in p and "/.worktrees/" not in p]
        if not br.strip():
            I.append(f"{r['name']}: detached HEAD in the main checkout")
        if baks:
            I.append(f"{r['name']}: stale env backup copies: {', '.join(sorted(baks)[:6])} (not removed; delete by hand when sure)")
        if dirty:
            I.append(f"{r['name']}: {dirty} uncommitted file(s)")


def check_auth(man, env):
    if HOST == "mac":
        p = os.path.join(PIPE_CFG, "oauth-token")
        if not os.path.exists(p):
            drift("auth:claude", "headless claude token file ~/.claude/pipeline/oauth-token missing")
        elif stat.S_IMODE(os.stat(p).st_mode) & 0o077:
            os.chmod(p, 0o600); F.append("oauth-token file permissions tightened to 600")
    else:
        if not os.path.exists(os.path.join(HOME, ".claude", ".credentials.json")):
            drift("auth:claude", "VM claude login (~/.claude/.credentials.json) missing", "ssh to the VM and run claude /login")
    rc, out = run(["gh", "auth", "status"], env=env)
    if rc != 0:
        drift("auth:gh", "gh is not authenticated")
    else:
        m = re.search(r"Token scopes: (.*)", out)
        have = set(re.findall(r"'([^']+)'", m.group(1))) if m else set()
        need = set(man.get("gh_scopes_required", []))
        if need - have:
            drift("auth:gh-scopes", "gh token lacks scopes: " + ", ".join(sorted(need - have)), "gh auth refresh -s " + ",".join(sorted(need - have)))
    if shutil.which("wrangler", path=env["PATH"]):
        rc, out = run(["wrangler", "whoami"], timeout=40, env=env)
        low = out.lower()
        if rc != 0 or "not authenticated" in low or "expired" in low or "invalid" in low:
            drift("auth:wrangler", "wrangler (Cloudflare) login is expired or missing on this host", "Mac -> VM: bin/vm-sync.sh creds (after a fresh wrangler login on the Mac)")


def check_memory():
    conf = os.path.join(PIPE_CFG, "memory-sync.conf")
    remote = ""
    if os.path.exists(conf):
        m = re.search(r'^MEMORY_REMOTE=["\']?([^"\'\n]*)', open(conf).read(), re.M)
        remote = m.group(1).strip() if m else ""
    if not remote:
        P.append("memory sync: storage backend not chosen (MEMORY_REMOTE unset in ~/.claude/pipeline/memory-sync.conf); Mac and VM memory still diverge")
        return
    st = os.path.join(PIPE_CFG, "memory-sync.last-ok")
    age = time.time() - os.path.getmtime(st) if os.path.exists(st) else None
    if age is None or age > 2 * 86400:
        drift("memory:stale", "memory sync has not completed in over 2 days" if age else "memory sync has never completed", "bin/memory-sync.py")


# ---------------------------------------------------------------- alert (one issue per host, only on change)
def alert(drifts):
    sig = hashlib.sha256(json.dumps(sorted(d["id"] + d["msg"] for d in drifts)).encode()).hexdigest()
    last = os.path.join(PIPE_CFG, "host-drift.last")
    prev = open(last).read().strip() if os.path.exists(last) else ""
    if sig == prev:
        return
    title = f"Host drift: {HOST}"
    rc, out = run(["gh", "issue", "list", "-R", ALERT_REPO, "--label", "host-drift", "--state", "all", "--search", f'"{title}" in:title',
                   "--json", "number,state,title"])
    issues = [i for i in (json.loads(out) if rc == 0 and out.strip().startswith("[") else []) if i["title"] == title]
    if rc != 0:
        return  # offline: try again next run (signature not saved)
    # This repo is PUBLIC: the issue carries drift ids only (no paths, no file names). Details stay in the host snapshot.
    ids = "\n".join("- " + re.sub(r":[^:]*\.env[^:]*$", ":<env file>", d["id"]) for d in drifts) or "Clean."
    body = f"Automatic report from bin/host-drift.py on {HOST} ({time.strftime('%Y-%m-%d %H:%MZ', time.gmtime())}).\n\n{ids}\n\nDetails on the host: python3 bin/host-drift.py (or ~/.claude/pipeline/host-snapshot.json).\n"
    if drifts:
        run(["gh", "label", "create", "host-drift", "-R", ALERT_REPO, "--color", "B60205", "--description", "daily host drift report"])
        if issues:
            n = str(issues[0]["number"])
            if issues[0]["state"] == "CLOSED":
                run(["gh", "issue", "reopen", n, "-R", ALERT_REPO])
            run(["gh", "issue", "comment", n, "-R", ALERT_REPO, "--body", body])
        else:
            run(["gh", "issue", "create", "-R", ALERT_REPO, "--title", title, "--label", "host-drift", "--body", body])
    elif issues and issues[0]["state"] == "OPEN":
        n = str(issues[0]["number"])
        run(["gh", "issue", "comment", n, "-R", ALERT_REPO, "--body", "Clean now. Closing."])
        run(["gh", "issue", "close", n, "-R", ALERT_REPO])
    os.makedirs(PIPE_CFG, exist_ok=True)
    open(last, "w").write(sig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fix", action="store_true"); ap.add_argument("--alert", action="store_true")
    ap.add_argument("--json", action="store_true"); ap.add_argument("--manifest")
    a = ap.parse_args()
    repo_root = find_repo_root()
    man = json.load(open(a.manifest or os.path.join(repo_root, "infra", "host-manifest.json")))
    man.setdefault("gh_scopes_required", ["repo", "workflow"])
    repo = os.path.realpath(x(next(r[HOST] for r in man["repos"] if r["name"] == "claude-agents")))
    env = pipeline_env()

    check_symlinks(repo)
    check_code(repo, a.fix)
    check_tools(man, env)
    check_config(man)
    check_supervisor()
    check_repos(man, a.fix)
    check_auth(man, env)
    check_memory()

    if a.fix and any(d["id"] == "path:vm-noninteractive" for d in D):
        if fix_vm_path():
            F.append("added ~/.local/bin to the top of ~/.bashrc (non-interactive ssh now finds the current claude)")
            D[:] = [d for d in D if d["id"] != "path:vm-noninteractive"]
    snap = {"host": HOST, "at": time.strftime("%FT%TZ", time.gmtime()), "drift": D, "fixed": F, "info": I, "pending": P}
    os.makedirs(PIPE_CFG, exist_ok=True)
    json.dump(snap, open(os.path.join(PIPE_CFG, "host-snapshot.json"), "w"), indent=1)
    if a.alert:
        alert(D)
    if a.json:
        print(json.dumps(snap, indent=1))
    else:
        for f in F:
            print("fixed: " + f)
        for d in D:
            print("DRIFT: " + d["msg"] + (f"  [{d['hint']}]" if d.get("hint") else ""))
    sys.exit(1 if D else 0)


if __name__ == "__main__":
    main()
