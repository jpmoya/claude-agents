#!/usr/bin/env python3
"""Memory sync between the Mac and the Clog VM (docs/host-sync.md).

  memory-sync.py [--dry-run] [--conf PATH]

Syncs every ~/.claude/projects/<dir>/memory/ folder through ONE private git remote. The storage backend is a single
config value, MEMORY_REMOTE, in ~/.claude/pipeline/memory-sync.conf (not tracked). Unset = this tool does nothing and
reports "not configured". Choosing where private memory lives and who can read it is JP's call.

Rules (nothing is ever deleted, on either side):
  * Project dirs are keyed logically so different paths meet: the home project is `home`; a project whose encoded path
    ends in a manifest repo's mac/vm path is `repo-<name>`; anything else keeps its name with the home prefix normalised.
  * 3-way merge per file against the hash recorded at the last sync (memory-sync.state.json):
      only local changed -> push local; only store changed -> take store; both changed -> the store copy wins and the
      local copy is kept next to it as <name>.conflict-<host>-<date>.md (no content lost). MEMORY.md is line-unioned.
  * A file that looks like it holds a credential is NEVER pushed (names reported, values never printed).
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, time

HOME = os.path.expanduser("~")
HOST = os.environ.get("HOST_ID") or ("mac" if sys.platform == "darwin" else "vm")
PIPE_CFG = os.path.join(HOME, ".claude", "pipeline")
SECRET_RES = [re.compile(p) for p in (
    r"xox[abprs]-[0-9A-Za-z-]{10,}", r"gh[pousr]_[0-9A-Za-z]{20,}", r"github_pat_[0-9A-Za-z_]{20,}", r"sk-[A-Za-z0-9_-]{20,}",
    r"sbp_[0-9a-f]{20,}", r"eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}\.", r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    r"(?i)\b[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_?KEY|SERVICE_ROLE_KEY|PAT)\b\s*[=:]\s*['\"]?[A-Za-z0-9_\-./+=]{24,}",
    r"AKIA[0-9A-Z]{16}",
)]


def sh(*a, cwd=None, check=False):
    r = subprocess.run(a, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(f"{' '.join(a[:3])} failed: {(r.stderr or r.stdout).strip()[:200]}")
    return r


def sha(b):
    return hashlib.sha256(b).hexdigest()


def load_conf(path):
    conf = {"MEMORY_REMOTE": "", "MEMORY_STORE": os.path.join(HOME, ".claude", "memory-store")}
    if os.path.exists(path):
        for m in re.finditer(r'^([A-Z_]+)=["\']?([^"\'\n]*)', open(path).read(), re.M):
            conf[m.group(1)] = os.path.expandvars(os.path.expanduser(m.group(2).strip())) if m.group(1) == "MEMORY_STORE" else m.group(2).strip()
    return conf


def project_keys():
    """encoded project dir name -> logical key, for dirs that have a memory/ folder with files."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    man = json.load(open(os.path.join(root, "infra", "host-manifest.json")))
    enc = lambda p: os.path.expanduser(p).replace("/", "-").replace(".", "-")
    home_enc = enc(HOME)
    repo_enc = {}
    for r in man["repos"]:
        for h in ("mac", "vm"):
            if r.get(h):
                # paths from either host: normalise "~" to this host's home so encoded names compare
                repo_enc[r[h].replace("~", "HOME")] = r["name"]
    out = {}
    pdir = os.path.join(HOME, ".claude", "projects")
    for d in sorted(os.listdir(pdir)) if os.path.isdir(pdir) else []:
        mem = os.path.join(pdir, d, "memory")
        if not (os.path.isdir(mem) and os.listdir(mem)):
            continue
        if d == home_enc:
            out[d] = "home"; continue
        key = None
        if d.startswith(home_enc + "-"):
            rest = d[len(home_enc) + 1:]
            for rp, name in repo_enc.items():
                if rest == rp.replace("HOME/", "").replace("/", "-").replace(".", "-"):
                    key = "repo-" + name; break
            key = key or "path-" + rest
        else:
            key = "other-" + d
        out[d] = key
    return out


def secret_hit(data):
    t = data.decode("utf-8", "ignore")
    return any(r.search(t) for r in SECRET_RES)


def union_lines(a, b):
    seen, out = set(), []
    for line in (a.decode("utf-8", "ignore") + "\n" + b.decode("utf-8", "ignore")).splitlines():
        k = line.strip()
        if k and k in seen:
            continue
        if k:
            seen.add(k)
        out.append(line)
    return ("\n".join(out).rstrip() + "\n").encode()


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--dry-run", action="store_true"); ap.add_argument("--conf")
    a = ap.parse_args()
    conf = load_conf(a.conf or os.path.join(PIPE_CFG, "memory-sync.conf"))
    if not conf["MEMORY_REMOTE"]:
        print("memory-sync: not configured (MEMORY_REMOTE unset) - nothing done"); return 0
    store = conf["MEMORY_STORE"]
    if not os.path.isdir(os.path.join(store, ".git")):
        r = sh("git", "clone", "-q", conf["MEMORY_REMOTE"], store)
        if r.returncode:
            print("memory-sync: cannot clone the store: " + r.stderr.strip()[:200]); return 1
    sh("git", "config", "user.email", "memory-sync@" + HOST, cwd=store); sh("git", "config", "user.name", "memory-sync " + HOST, cwd=store)
    branch = (sh("git", "symbolic-ref", "--short", "-q", "HEAD", cwd=store).stdout.strip() or "main")
    if sh("git", "ls-remote", "--heads", "origin", cwd=store).stdout.strip():
        r = sh("git", "pull", "-q", "--rebase", "origin", branch, cwd=store)
        if r.returncode:
            sh("git", "rebase", "--abort", cwd=store); print("memory-sync: store pull failed: " + r.stderr.strip()[:200]); return 1
    st_path = os.path.join(PIPE_CFG, "memory-sync.state.json")
    state = json.load(open(st_path)) if os.path.exists(st_path) else {}
    stamp = time.strftime("%Y%m%d")
    blocked, pushed, pulled, conflicts = [], 0, 0, 0
    for d, key in project_keys().items():
        lmem = os.path.join(HOME, ".claude", "projects", d, "memory")
        smem = os.path.join(store, "memory", key)
        rels = set()
        for base in (lmem, smem):
            for dp, _, fs in os.walk(base):
                for f in fs:
                    rels.add(os.path.relpath(os.path.join(dp, f), base))
        for rel in sorted(rels):
            lp, sp = os.path.join(lmem, rel), os.path.join(smem, rel)
            lb = open(lp, "rb").read() if os.path.isfile(lp) else None
            sb = open(sp, "rb").read() if os.path.isfile(sp) else None
            lh, sh_ = (sha(lb) if lb is not None else None), (sha(sb) if sb is not None else None)
            sk = f"{key}/{rel}"
            base = state.get(sk)
            if lh == sh_:
                state[sk] = lh; continue
            def put(path, data):
                if a.dry_run: return
                os.makedirs(os.path.dirname(path), exist_ok=True); open(path, "wb").write(data)
            if sb is None or (lh != base and sh_ == base):          # local-only change: push
                if secret_hit(lb):
                    blocked.append(sk); continue
                put(sp, lb); pushed += 1; state[sk] = lh
            elif lb is None or (sh_ != base and lh == base):        # store-only change: take
                put(lp, sb); pulled += 1; state[sk] = sh_
            else:                                                   # both changed
                if rel == "MEMORY.md":
                    if secret_hit(lb): blocked.append(sk); continue
                    merged = union_lines(sb, lb); put(sp, merged); put(lp, merged); state[sk] = sha(merged)
                else:
                    if secret_hit(lb): blocked.append(sk); continue
                    cname = re.sub(r"\.md$", "", rel) + f".conflict-{HOST}-{stamp}.md"
                    put(os.path.join(smem, cname), lb); put(os.path.join(lmem, cname), lb)
                    put(lp, sb); state[sk] = sh_; conflicts += 1
    if not a.dry_run:
        os.makedirs(PIPE_CFG, exist_ok=True); json.dump(state, open(st_path, "w"), indent=0)
        sh("git", "add", "-A", cwd=store)
        if sh("git", "status", "--porcelain", cwd=store).stdout.strip():
            sh("git", "commit", "-q", "-m", f"memory sync from {HOST}", cwd=store)
        for _ in range(2):
            r = sh("git", "push", "-q", "origin", f"HEAD:{branch}", cwd=store)
            if r.returncode == 0:
                break
            sh("git", "pull", "-q", "--rebase", "origin", branch, cwd=store)
        else:
            print("memory-sync: push failed: " + r.stderr.strip()[:200]); return 1
        open(os.path.join(PIPE_CFG, "memory-sync.last-ok"), "w").write(time.strftime("%FT%TZ", time.gmtime()))
    print(f"memory-sync: pushed {pushed}, pulled {pulled}, conflicts kept {conflicts}, blocked-as-secret {len(blocked)}")
    for b in blocked:
        print("  NOT PUSHED (looks like a credential, scrub it): " + b)
    return 0


if __name__ == "__main__":
    sys.exit(main())
