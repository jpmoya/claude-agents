#!/usr/bin/env python3
"""GitHub webhook receiver for the pipeline supervisor (#773). Python stdlib only.

Routes (anything else: 404, or 405 for a known path with the wrong method):
  POST /webhook   a GitHub delivery. Signature (X-Hub-Signature-256) is verified over the raw body before any parsing.
  GET  /events    ?since=<seq>[&limit=<n>]  queued events newer than <seq>; bearer token required.
  GET  /health    {"ok": true}, nothing else.

The receiver only ever writes one JSON line per event to <state dir>/events.jsonl:
  {"seq","ts","delivery","event","action","repo","owner","number","sender"}
Never the payload body (no titles, comments, emails, tokens). Every stored string is matched against a strict
pattern first, and consumers read the file with jq, never eval or an unquoted expansion.

Binds 127.0.0.1 by default; TLS is Caddy's job (infra/webhook/Caddyfile). Configuration comes from the environment
(webhook-receiver.sh exports it from config.sh / config.local.sh): the secrets are never taken from argv and never logged.
"""
import hashlib
import hmac
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

ALLOWED_EVENTS = (
    "issues", "issue_comment", "pull_request", "check_run", "check_suite", "workflow_run", "projects_v2_item",
)
RE_EVENT = re.compile(r"^[a-z0-9_]{1,40}$")
RE_ACTION = re.compile(r"^[a-z_]{1,40}$")
RE_DELIVERY = re.compile(r"^[A-Za-z0-9-]{8,64}$")
RE_REPO = re.compile(r"^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$")
RE_OWNER = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
RE_LOGIN = re.compile(r"^[A-Za-z0-9._\[\]-]{1,100}$")
RE_SIG = re.compile(r"^sha256=([0-9a-fA-F]{64})$")
MIN_SECRET_LEN = 16


def env_int(name, default, minimum=0):
    try:
        value = int(os.environ.get(name, "") or default)
    except ValueError:
        value = default
    return max(minimum, value)


class Config:
    def __init__(self):
        self.secret = os.environ.get("WEBHOOK_SECRET", "")
        self.token = os.environ.get("WEBHOOK_PULL_TOKEN", "")
        pipe = os.environ.get("PIPE") or os.path.expanduser("~/.claude/pipeline/state")
        self.state_dir = os.environ.get("WEBHOOK_STATE_DIR") or os.path.join(pipe, "webhook")
        self.bind = os.environ.get("WEBHOOK_BIND", "127.0.0.1")
        self.port = env_int("WEBHOOK_PORT", 8787)
        self.max_body = env_int("WEBHOOK_MAX_BODY_BYTES", 1048576, 1)
        self.rate_limit = env_int("WEBHOOK_RATE_LIMIT_PER_MIN", 120, 1)
        self.seen_ttl = env_int("WEBHOOK_SEEN_TTL_SECS", 86400, 60)
        self.queue_max_bytes = env_int("WEBHOOK_QUEUE_MAX_BYTES", 8 * 1024 * 1024, 1024)
        self.events_page_max = env_int("WEBHOOK_EVENTS_PAGE_MAX", 1000, 1)
        self.timeout = env_int("WEBHOOK_HANDLER_TIMEOUT_SECS", 10, 1)
        self.trusted_proxies = {p.strip() for p in os.environ.get("WEBHOOK_TRUSTED_PROXIES", "127.0.0.1,::1").split(",") if p.strip()}
        self.slack_url = os.environ.get("SLACK_WEBHOOK_URL", "")
        self.alert_interval = env_int("WEBHOOK_ALERT_INTERVAL_SECS", 600, 1)


def release_tag():
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        out = subprocess.run(["git", "-C", here, "rev-parse", "--short", "HEAD"], capture_output=True, text=True, timeout=5)
        return out.stdout.strip() or "unknown"
    except Exception:
        return "unknown"


class Alerter:
    """Errors on the receiver path: one stderr line plus (at most one per interval) a Slack post through the existing
    SLACK_WEBHOOK_URL. Tags only (release = commit SHA, environment = host, route); never an exception message, a payload or a secret."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.release = release_tag()
        self.environment = socket.gethostname().split(".")[0] or "unknown"
        self.last = 0.0
        self.lock = threading.Lock()

    def tags(self, route):
        return "release=%s environment=%s route=%s" % (self.release, self.environment, route)

    def alert(self, what, route="webhook-receiver"):
        text = "webhook receiver error: %s: %s" % (what, self.tags(route))
        sys.stderr.write(text + "\n")
        sys.stderr.flush()
        if not self.cfg.slack_url:
            return
        with self.lock:
            now = time.time()
            if now - self.last < self.cfg.alert_interval:
                return
            self.last = now
        try:
            req = urllib.request.Request(
                self.cfg.slack_url, data=json.dumps({"text": text}).encode(),
                headers={"Content-Type": "application/json"}, method="POST")
            urllib.request.urlopen(req, timeout=5).close()
        except Exception:
            sys.stderr.write("webhook receiver: slack alert failed: %s\n" % self.tags(route))


class Queue:
    """Append-only JSONL queue with a monotonically increasing sequence and a persisted delivery-id window."""

    def __init__(self, cfg):
        self.cfg = cfg
        os.makedirs(cfg.state_dir, mode=0o700, exist_ok=True)
        self.path = os.path.join(cfg.state_dir, "events.jsonl")
        self.seen_path = os.path.join(cfg.state_dir, "seen-deliveries")
        self.lock = threading.Lock()
        self.seq = self._last_seq()
        self.seen = self._load_seen()

    @staticmethod
    def _parse(line):
        try:
            obj = json.loads(line)
        except ValueError:
            return None
        return obj if isinstance(obj, dict) and isinstance(obj.get("seq"), int) else None

    def _read_events(self):
        out = []
        try:
            with open(self.path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    ev = self._parse(line)
                    if ev is not None:
                        out.append(ev)
        except FileNotFoundError:
            pass
        return out

    def _last_seq(self):
        events = self._read_events()
        return events[-1]["seq"] if events else 0

    def _load_seen(self):
        seen = {}
        cutoff = time.time() - self.cfg.seen_ttl
        try:
            with open(self.seen_path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) == 2 and parts[0].isdigit() and RE_DELIVERY.match(parts[1]) and int(parts[0]) >= cutoff:
                        seen[parts[1]] = int(parts[0])
        except FileNotFoundError:
            pass
        tmp = self.seen_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("".join("%d %s\n" % (ts, d) for d, ts in seen.items()))
        os.replace(tmp, self.seen_path)
        return seen

    def _prune_seen(self, now):
        cutoff = now - self.cfg.seen_ttl
        stale = [d for d, ts in self.seen.items() if ts < cutoff]
        for d in stale:
            del self.seen[d]

    def append(self, record):
        """Returns the queued record, or None when the delivery id was already seen."""
        with self.lock:
            now = int(time.time())
            self._prune_seen(now)
            if record["delivery"] in self.seen:
                return None
            record = dict(record, seq=self.seq + 1, ts=now)
            line = json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n"
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                os.write(fd, line.encode())
                os.fsync(fd)
            finally:
                os.close(fd)
            self.seq = record["seq"]
            self.seen[record["delivery"]] = now
            with open(self.seen_path, "a", encoding="utf-8") as fh:
                fh.write("%d %s\n" % (now, record["delivery"]))
            self._compact_if_needed()
            return record

    def _compact_if_needed(self):
        try:
            if os.path.getsize(self.path) <= self.cfg.queue_max_bytes:
                return
        except OSError:
            return
        events = self._read_events()
        keep = events[len(events) // 2:]
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            for ev in keep:
                fh.write(json.dumps(ev, separators=(",", ":"), sort_keys=True) + "\n")
        os.replace(tmp, self.path)

    def since(self, since, limit):
        with self.lock:
            events = self._read_events()
        newer = [e for e in events if e["seq"] > since][:limit]
        return {"latest": events[-1]["seq"] if events else 0, "oldest": events[0]["seq"] if events else 0, "events": newer}


def valid_number(n):
    return n if isinstance(n, int) and not isinstance(n, bool) and 0 < n < 10**9 else None


def issue_number(payload, key):
    obj = payload.get(key)
    return valid_number(obj.get("number")) if isinstance(obj, dict) else None


def first_pr_number(obj):
    prs = obj.get("pull_requests") if isinstance(obj, dict) else None
    if isinstance(prs, list) and prs and isinstance(prs[0], dict):
        return valid_number(prs[0].get("number"))
    return None


def build_record(event, delivery, payload):
    """Only validated, bounded fields; anything that does not match its pattern becomes null. Never copies free text."""
    def pick(value, pattern):
        return value if isinstance(value, str) and pattern.match(value) else None
    repo = pick((payload.get("repository") or {}).get("full_name") if isinstance(payload.get("repository"), dict) else None, RE_REPO)
    org = payload.get("organization") if isinstance(payload.get("organization"), dict) else {}
    repo_owner = (payload.get("repository") or {}).get("owner") if isinstance(payload.get("repository"), dict) else None
    owner = pick(org.get("login"), RE_OWNER) or pick(repo_owner.get("login") if isinstance(repo_owner, dict) else None, RE_OWNER)
    if event in ("issues", "issue_comment"):
        number = issue_number(payload, "issue")
    elif event == "pull_request":
        number = issue_number(payload, "pull_request") or valid_number(payload.get("number"))
    elif event in ("check_run", "check_suite", "workflow_run"):
        number = first_pr_number(payload.get(event))
    else:
        number = None
    sender = payload.get("sender") if isinstance(payload.get("sender"), dict) else {}
    return {
        "delivery": delivery, "event": event, "action": pick(payload.get("action"), RE_ACTION),
        "repo": repo, "owner": owner, "number": number, "sender": pick(sender.get("login"), RE_LOGIN),
    }


class RateLimiter:
    def __init__(self, per_minute):
        self.per_minute = per_minute
        self.hits = {}
        self.lock = threading.Lock()

    def allow(self, source):
        now = time.monotonic()
        with self.lock:
            q = self.hits.setdefault(source, deque())
            while q and now - q[0] >= 60:
                q.popleft()
            if len(q) >= self.per_minute:
                return False
            q.append(now)
            if len(self.hits) > 10000:
                for k in [k for k, v in self.hits.items() if not v or now - v[-1] >= 60]:
                    del self.hits[k]
            return True


ROUTES = {"/webhook": "POST", "/events": "GET", "/health": "GET"}


class Handler(BaseHTTPRequestHandler):
    server_version = "pipeline-webhook"
    sys_version = ""
    # HTTP/1.0 (the default): one request per connection, so an unread body can never leak into the next request.

    def setup(self):
        self.timeout = self.server.cfg.timeout
        super().setup()

    def log_message(self, fmt, *args):  # the default logs the request line and client; we log method, path, status only
        pass

    def _reply(self, status, body=None, headers=None):
        data = json.dumps(body if body is not None else {}, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        sys.stderr.write("%s %s %s %d\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), self.command, urlsplit(self.path).path[:64], status))
        sys.stderr.flush()

    def _source(self):
        peer = self.client_address[0]
        if peer in self.server.cfg.trusted_proxies:
            xff = self.headers.get("X-Forwarded-For", "")
            last = xff.split(",")[-1].strip() if xff else ""
            if last and len(last) <= 64 and re.match(r"^[0-9A-Fa-f:.]+$", last):
                return last
        return peer

    def _dispatch(self):
        try:
            self._route()
        except Exception as exc:  # never leak internals; the alert carries only the class name
            try:
                self.server.alerter.alert("handler %s" % type(exc).__name__)
                self._reply(500, {"error": "internal"})
            except Exception:
                pass

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _dispatch

    def _route(self):
        path = urlsplit(self.path).path
        want = ROUTES.get(path)
        if want is None:
            return self._reply(404, {"error": "not found"})
        if self.command != want:
            return self._reply(405, {"error": "method not allowed"}, {"Allow": want})
        if not self.server.limiter.allow(self._source()):
            return self._reply(429, {"error": "rate limited"}, {"Retry-After": "60"})
        if path == "/health":
            return self._reply(200, {"ok": True})
        if path == "/events":
            return self._events()
        return self._webhook()

    def _events(self):
        cfg = self.server.cfg
        auth = self.headers.get("Authorization", "")
        got = auth[7:] if auth.startswith("Bearer ") else ""
        if not got or not hmac.compare_digest(got.encode(), cfg.token.encode()):
            return self._reply(401, {"error": "unauthorized"}, {"WWW-Authenticate": "Bearer"})
        qs = parse_qs(urlsplit(self.path).query)
        try:
            since = int(qs.get("since", ["0"])[0])
            limit = int(qs.get("limit", [str(cfg.events_page_max)])[0])
        except ValueError:
            return self._reply(400, {"error": "bad query"})
        if since < 0 or limit < 1:
            return self._reply(400, {"error": "bad query"})
        return self._reply(200, self.server.queue.since(since, min(limit, cfg.events_page_max)))

    def _drain(self, length):
        left = min(length, 2 * self.server.cfg.max_body)
        try:
            while left > 0:
                chunk = self.rfile.read(min(65536, left))
                if not chunk:
                    break
                left -= len(chunk)
        except OSError:
            pass

    def _webhook(self):
        cfg = self.server.cfg
        if self.headers.get("Transfer-Encoding"):
            return self._reply(411, {"error": "content-length required"})
        raw_len = self.headers.get("Content-Length")
        if raw_len is None:
            return self._reply(411, {"error": "content-length required"})
        if not raw_len.isdigit() or len(raw_len) > 12:
            return self._reply(400, {"error": "bad content-length"})
        length = int(raw_len)
        if length > cfg.max_body:
            self._reply(413, {"error": "body too large"})
            self._drain(length)  # discard (never store) what the client is still sending, so closing does not RST the reply away
            return
        body = self.rfile.read(length)
        if len(body) != length:
            return self._reply(400, {"error": "short body"})
        match = RE_SIG.match(self.headers.get("X-Hub-Signature-256", ""))
        expected = hmac.new(cfg.secret.encode(), body, hashlib.sha256).hexdigest()
        if not match or not hmac.compare_digest(expected, match.group(1).lower()):
            return self._reply(401, {"error": "bad signature"})
        event = self.headers.get("X-GitHub-Event", "")
        if not RE_EVENT.match(event):
            return self._reply(400, {"error": "bad event"})
        if event == "ping":
            return self._reply(200, {"ok": True, "pong": True})
        delivery = self.headers.get("X-GitHub-Delivery", "")
        if not RE_DELIVERY.match(delivery):
            return self._reply(400, {"error": "bad delivery id"})
        try:
            payload = json.loads(body.decode("utf-8"))
        except ValueError:
            return self._reply(400, {"error": "bad json"})
        if not isinstance(payload, dict):
            return self._reply(400, {"error": "bad json"})
        if event not in ALLOWED_EVENTS:
            return self._reply(200, {"queued": False, "ignored": True})
        queued = self.server.queue.append(build_record(event, delivery, payload))
        if queued is None:
            return self._reply(200, {"queued": False, "duplicate": True})
        return self._reply(202, {"queued": True, "seq": queued["seq"]})


def main():
    cfg = Config()
    if len(cfg.secret) < MIN_SECRET_LEN or len(cfg.token) < MIN_SECRET_LEN:
        sys.stderr.write("webhook-receiver: WEBHOOK_SECRET and WEBHOOK_PULL_TOKEN must each be set (>= %d chars); refusing to start\n" % MIN_SECRET_LEN)
        return 2
    if cfg.secret == cfg.token:
        sys.stderr.write("webhook-receiver: WEBHOOK_SECRET and WEBHOOK_PULL_TOKEN must differ; refusing to start\n")
        return 2
    server = HTTPServer((cfg.bind, cfg.port), Handler)
    server.cfg = cfg
    server.alerter = Alerter(cfg)
    try:
        server.queue = Queue(cfg)
    except OSError as exc:
        server.alerter.alert("queue init %s" % type(exc).__name__)
        return 1
    server.limiter = RateLimiter(cfg.rate_limit)
    sys.stdout.write("listening %s:%d\n" % server.server_address[:2])
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
