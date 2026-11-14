// src/index.js — router, bearer auth, Google sign-in, rate limiting, response headers.
//
// Routes: POST /beat, GET /status.json, GET /, GET /pipelines, GET /ci, GET /sales-agents,
// POST /backlog-priority, POST /learnings/push, GET /learnings, POST /learnings/edit,
// POST /learnings/delete, GET /robots.txt, GET /login, GET /auth/callback, else 404.
// X-Robots-Tag: noindex is applied in one place to every response.
//
// POST /beat auth is unchanged: a pure-JS constant-time compare (XOR-accumulate, no early
// return — crypto.subtle.timingSafeEqual doesn't exist in the Node test runtime) against both
// TOKEN_MAC and TOKEN_VM, with no early exit; the host label is whichever secret matched, never
// read from the body. Rate limiting is a module-scope Map keyed by CF-Connecting-IP, fixed 60s
// window, bounded eviction, reset via __resetRateLimiter for vitest. Neither /beat's auth nor
// its rate limiter apply to the human-facing routes below. POST /learnings/push reuses this same
// TOKEN_MAC/TOKEN_VM check and rate limiter — it's pushed from the same Mac, by a script that
// reads the same host config as the pipeline reporter (skills/orchestrate/push-learnings.sh), so
// a separate secret would buy no real isolation, just another `wrangler secret put` to forget.
//
// The human-facing routes (GET /, /status.json, /pipelines, /learnings) require a signed session
// cookie (Google OAuth 2.0 Authorization Code flow, see src/auth.js): unauthenticated -> 302 to
// /login -> 302 to Google -> /auth/callback exchanges the code, checks the ALLOWED_EMAILS
// allowlist, and issues the session cookie. See issue #11 / #4 §5 for the pre-existing
// routes/validation tables. POST /learnings/edit and /learnings/delete are behind the same
// session cookie (plain HTML forms, no JS, no new CSRF mechanism — SameSite=Lax already blocks a
// cross-site POST from carrying the cookie, same as every other human-facing write here).

import { validateBeatPayload } from "./validate.js";
import {
  renderPage,
  renderPipelines,
  renderCiPage,
  renderLearnings,
  renderSalesAgents,
} from "./render.js";
import { captureError } from "./capture.js";
import { KEEPALIVE_SECS, computeThresholds } from "./vocab.js";
import { setBacklogPriority, isValidKeyList } from "./backlog-priority.js";
import {
  parseLearningsMarkdown,
  loadLearningsRecord,
  mergePushedLines,
  editLearningEntry,
  deleteLearningEntry,
  MAX_LEARNINGS_PUSH_BYTES,
} from "./learnings.js";
import {
  requireSession,
  isConfiguredSecret as isConfiguredAuthSecret,
  buildGoogleAuthUrl,
  exchangeCodeForTokens,
  fetchGoogleUserinfo,
  isEmailAllowed,
  signSession,
  signState,
  verifyState,
  buildCookie,
  clearCookie,
  parseCookies,
  SESSION_COOKIE_NAME,
  SESSION_MAX_AGE_SECS,
  STATE_COOKIE_NAME,
  STATE_COOKIE_MAX_AGE_SECS,
} from "./auth.js";

const MAX_BEAT_BYTES = 128 * 1024; // 128 KB cap (#62; "> 128 KB" -> 413)
const RATE_LIMIT_WINDOW_MS = 60_000;
const RATE_LIMIT_MAX_PER_WINDOW = 60;
const RATE_LIMIT_EVICTION_BATCH = 1000; // bounded eviction — an isolate can live a long time

let rateLimitState = new Map();

/**
 * Constant-time string compare. No early return on mismatch.
 * @param {string} a
 * @param {string} b
 * @returns {boolean}
 */
export function constantTimeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const len = Math.max(a.length, b.length);
  let diff = a.length ^ b.length;
  for (let i = 0; i < len; i++) {
    const ca = i < a.length ? a.charCodeAt(i) : 0;
    const cb = i < b.length ? b.charCodeAt(i) : 0;
    diff |= ca ^ cb;
  }
  return diff === 0;
}

/** Resets the module-scope rate-limit state. Test-only export so vitest cases aren't order-dependent. */
export function __resetRateLimiter() {
  rateLimitState.clear();
}

/** True if `ip` has exceeded the fixed 60s / 60-request window. Bounds eviction per call. */
function isRateLimited(ip) {
  const now = Date.now();

  let evicted = 0;
  for (const [key, entry] of rateLimitState) {
    if (now - entry.windowStart >= RATE_LIMIT_WINDOW_MS) {
      rateLimitState.delete(key);
      evicted++;
      if (evicted >= RATE_LIMIT_EVICTION_BATCH) break;
    }
  }

  let entry = rateLimitState.get(ip);
  if (!entry || now - entry.windowStart >= RATE_LIMIT_WINDOW_MS) {
    entry = { count: 0, windowStart: now };
    rateLimitState.set(ip, entry);
  }
  entry.count++;
  return entry.count > RATE_LIMIT_MAX_PER_WINDOW;
}

function noindexResponse(body, init = {}) {
  const response = new Response(body, init);
  response.headers.set("X-Robots-Tag", "noindex");
  return response;
}

function extractBearerToken(request) {
  const header = request.headers.get("Authorization") || "";
  const match = /^Bearer\s+(.+)$/.exec(header);
  return match ? match[1] : null;
}

/** True if `secret` is a real configured value, not a missing/blank binding. */
function isConfiguredSecret(secret) {
  return typeof secret === "string" && secret.length > 0;
}

async function handleBeat(request, env) {
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  if (isRateLimited(ip)) return noindexResponse(null, { status: 429 });

  const token = extractBearerToken(request);
  // Both compares always run (no early exit against either secret) — but an unconfigured
  // secret (missing `wrangler secret put`) never matches, even against an empty/missing
  // token, so a deploy that forgot to set TOKEN_MAC/TOKEN_VM fails closed, not open.
  const okMac =
    isConfiguredSecret(env.TOKEN_MAC) &&
    constantTimeEqual(token ?? "", env.TOKEN_MAC);
  const okVm =
    isConfiguredSecret(env.TOKEN_VM) &&
    constantTimeEqual(token ?? "", env.TOKEN_VM);
  let host = null;
  if (okMac) host = "mac";
  else if (okVm) host = "vm";
  if (!host) return noindexResponse(null, { status: 401 });

  const rawBody = await request.text();
  const byteLength = new TextEncoder().encode(rawBody).length;
  if (byteLength > MAX_BEAT_BYTES)
    return noindexResponse(null, { status: 413 });

  let parsed;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return noindexResponse(null, { status: 400 });
  }

  const result = validateBeatPayload(parsed);
  if (!result.ok) return noindexResponse(null, { status: 400 });

  const record = { ...result.value, received_at: new Date().toISOString() };
  await env.STATUS.put(`host:${host}`, JSON.stringify(record));
  return noindexResponse(null, { status: 204 });
}

async function readHostRecords(env) {
  const [macRaw, vmRaw] = await Promise.all([
    env.STATUS.get("host:mac"),
    env.STATUS.get("host:vm"),
  ]);
  return { mac: parseHostRecord(macRaw), vm: parseHostRecord(vmRaw) };
}

function parseHostRecord(raw) {
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function handleStatusJson(env) {
  const hosts = await readHostRecords(env);
  const { staleSecs, offlineSecs } = computeThresholds(KEEPALIVE_SECS);
  const body = JSON.stringify({
    v: 1,
    generated_at: new Date().toISOString(),
    keepalive_secs: KEEPALIVE_SECS,
    stale_secs: staleSecs,
    offline_secs: offlineSecs,
    hosts,
  });
  return noindexResponse(body, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "max-age=15",
    },
  });
}

async function handleHome(env) {
  const hosts = await readHostRecords(env);
  const thresholds = computeThresholds(KEEPALIVE_SECS);
  const nowEpochSecs = Math.floor(Date.now() / 1000);
  const html = renderPage(hosts, thresholds, nowEpochSecs);
  return noindexResponse(html, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "max-age=15",
    },
  });
}

async function handlePipelines(env) {
  try {
    const html = renderPipelines();
    return noindexResponse(html, {
      status: 200,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "max-age=15",
      },
    });
  } catch (err) {
    const tags = {
      release: env.RELEASE,
      environment: env.ENVIRONMENT,
      route: "/pipelines",
    };
    await captureError(err, tags, env);
    return noindexResponse("Internal error", {
      status: 500,
      headers: { "Content-Type": "text/plain" },
    });
  }
}

/** GET /sales-agents — static, server-rendered documentation of Benji's outbound-sales agent
 * pipeline (a separate repo, a separate system from the engineering pipeline on /pipelines). */
async function handleSalesAgents(env) {
  try {
    const html = renderSalesAgents();
    return noindexResponse(html, {
      status: 200,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "max-age=15",
      },
    });
  } catch (err) {
    const tags = {
      release: env.RELEASE,
      environment: env.ENVIRONMENT,
      route: "/sales-agents",
    };
    await captureError(err, tags, env);
    return noindexResponse("Internal error", {
      status: 500,
      headers: { "Content-Type": "text/plain" },
    });
  }
}

/** GET /ci — issue #649: the CI-queue panel + per-runner table, moved off `/` onto its own tab. */
async function handleCi(env) {
  try {
    const hosts = await readHostRecords(env);
    const thresholds = computeThresholds(KEEPALIVE_SECS);
    const nowEpochSecs = Math.floor(Date.now() / 1000);
    const html = renderCiPage(hosts, thresholds, nowEpochSecs);
    return noindexResponse(html, {
      status: 200,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "max-age=15",
      },
    });
  } catch (err) {
    const tags = {
      release: env.RELEASE,
      environment: env.ENVIRONMENT,
      route: "/ci",
    };
    await captureError(err, tags, env);
    return noindexResponse("Internal error", {
      status: 500,
      headers: { "Content-Type": "text/plain" },
    });
  }
}

/**
 * POST /backlog-priority — the authenticated write path the page's &uarr;/&darr; buttons call
 * (src/render.js's BACKLOG_REORDER_SCRIPT). Body: {"keys": ["owner/repo#issue", ...]}, highest
 * priority first (same order the page displays and the `backlog-priority.sh set` command
 * prints). Writes straight to the backlog-priority-registry GitHub issue via the REST API
 * (src/backlog-priority.js) — this Worker can't shell out to `gh`, so it is the second writer of
 * that same issue, not a new primitive. Gated by the same requireSession check as every other
 * human-facing route (checked by the caller in the router below, same as /, /pipelines, /status.json).
 */
async function handleBacklogPriority(request, env) {
  if (!isConfiguredAuthSecret(env.GITHUB_TOKEN)) {
    return noindexResponse("Backlog reorder is not configured yet", {
      status: 503,
      headers: { "Content-Type": "text/plain" },
    });
  }

  let parsed;
  try {
    parsed = JSON.parse(await request.text());
  } catch {
    return noindexResponse(null, { status: 400 });
  }

  const keys = parsed && parsed.keys;
  if (!isValidKeyList(keys)) return noindexResponse(null, { status: 400 });

  try {
    await setBacklogPriority(env.GITHUB_TOKEN, keys);
    return noindexResponse(null, { status: 204 });
  } catch (err) {
    const tags = {
      release: env.RELEASE,
      environment: env.ENVIRONMENT,
      route: "/backlog-priority",
    };
    await captureError(err, tags, env);
    return noindexResponse("Could not save the new order", {
      status: 502,
      headers: { "Content-Type": "text/plain" },
    });
  }
}

const LEARNINGS_KV_KEY = "learnings:entries";

async function readLearningsRecord(env) {
  return loadLearningsRecord(await env.STATUS.get(LEARNINGS_KV_KEY));
}

/**
 * POST /learnings/push — the Mac's one-way sync of message-triage-learnings.md into KV
 * (skills/orchestrate/push-learnings.sh). Same bearer auth and rate limiter as /beat; the raw
 * markdown body (capped at 64 KB) is parsed into bullet lines and merged (src/learnings.js) so a
 * line already pushed before is never re-added, even if it was since edited or deleted on the
 * page. KV is only written when the merge actually added a line — a re-push of unchanged content
 * (or a push scheduled more often than the file actually grows) costs nothing against the shared
 * KV write budget report-status.sh's AC12 comment documents, and never risks clobbering a browser
 * delete/edit that landed in KV after this handler's own read.
 */
async function handleLearningsPush(request, env) {
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  if (isRateLimited(ip)) return noindexResponse(null, { status: 429 });

  const token = extractBearerToken(request);
  const okMac =
    isConfiguredSecret(env.TOKEN_MAC) &&
    constantTimeEqual(token ?? "", env.TOKEN_MAC);
  const okVm =
    isConfiguredSecret(env.TOKEN_VM) &&
    constantTimeEqual(token ?? "", env.TOKEN_VM);
  if (!okMac && !okVm) return noindexResponse(null, { status: 401 });

  const rawBody = await request.text();
  const byteLength = new TextEncoder().encode(rawBody).length;
  if (byteLength > MAX_LEARNINGS_PUSH_BYTES)
    return noindexResponse(null, { status: 413 });

  const lines = parseLearningsMarkdown(rawBody);
  const record = await readLearningsRecord(env);
  const merged = mergePushedLines(record, lines);
  if (merged.seen.length > record.seen.length) {
    await env.STATUS.put(LEARNINGS_KV_KEY, JSON.stringify(merged));
  }
  return noindexResponse(null, { status: 204 });
}

/** GET /learnings — renders the current KV-stored list. `no-store`: a delete/edit redirects back
 * here and must never show a stale cached copy. */
async function handleLearningsPage(env) {
  const record = await readLearningsRecord(env);
  const html = renderLearnings(record.entries);
  return noindexResponse(html, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

/** POST /learnings/edit — plain HTML form (id, text). 400 for a missing id or blank text
 * (malformed request); 404 if `id` is well-formed but no longer exists. */
async function handleLearningsEdit(request, env) {
  let form;
  try {
    form = await request.formData();
  } catch {
    return noindexResponse(null, { status: 400 });
  }
  const id = form.get("id");
  const text = form.get("text");
  if (typeof id !== "string" || id === "")
    return noindexResponse(null, { status: 400 });
  if (typeof text !== "string" || text.trim() === "")
    return noindexResponse(null, { status: 400 });

  const record = await readLearningsRecord(env);
  const updated = editLearningEntry(record, id, text);
  if (!updated) return noindexResponse(null, { status: 404 });
  await env.STATUS.put(LEARNINGS_KV_KEY, JSON.stringify(updated));
  return redirectTo("/learnings", 303);
}

/** POST /learnings/delete — plain HTML form (id). Display-only: never touches the Mac file, and
 * never clears `seen`, so the next push can't bring the entry back. 404 if `id` no longer exists. */
async function handleLearningsDelete(request, env) {
  let form;
  try {
    form = await request.formData();
  } catch {
    return noindexResponse(null, { status: 400 });
  }
  const id = form.get("id");
  if (typeof id !== "string" || id === "")
    return noindexResponse(null, { status: 400 });

  const record = await readLearningsRecord(env);
  const updated = deleteLearningEntry(record, id);
  if (!updated) return noindexResponse(null, { status: 404 });
  await env.STATUS.put(LEARNINGS_KV_KEY, JSON.stringify(updated));
  return redirectTo("/learnings", 303);
}

function handleRobots() {
  return noindexResponse("User-agent: *\nDisallow: /\n", {
    status: 200,
    headers: { "Content-Type": "text/plain" },
  });
}

/** Redirect (302 by default) carrying X-Robots-Tag like every other response (never
 * Response.redirect — its headers are immutable). /learnings/edit and /learnings/delete pass 303
 * (POST -> GET) so a page reload never resubmits the form. */
function redirectTo(location, status = 302) {
  const headers = new Headers({ Location: location });
  return noindexResponse(null, { status, headers });
}

/**
 * Where Google sends the browser back. PUBLIC_ORIGIN (wrangler.jsonc vars) is the
 * host humans use — the Vercel front in vercel-proxy/ — because some ISPs block the
 * IPs *.workers.dev resolves to; through that front the worker only ever sees its own
 * workers.dev URL, so url.origin would send the browser straight back to the blocked
 * host. Falls back to the request origin when the var is unset.
 */
function callbackRedirectUri(url, env) {
  const origin =
    typeof env?.PUBLIC_ORIGIN === "string" && env.PUBLIC_ORIGIN.trim() !== ""
      ? env.PUBLIC_ORIGIN.trim().replace(/\/+$/, "")
      : url.origin;
  return `${origin}/auth/callback`;
}

/** GET /login — starts the Google OAuth flow for the human-facing routes. */
async function handleLogin(request, env) {
  if (
    !isConfiguredAuthSecret(env.GOOGLE_CLIENT_ID) ||
    !isConfiguredAuthSecret(env.SESSION_SECRET)
  ) {
    return noindexResponse("Sign-in is not configured yet", {
      status: 503,
      headers: { "Content-Type": "text/plain" },
    });
  }
  const url = new URL(request.url);
  const state = await signState(crypto.randomUUID(), env.SESSION_SECRET);
  const headers = new Headers();
  headers.append(
    "Set-Cookie",
    buildCookie(STATE_COOKIE_NAME, state, {
      maxAgeSecs: STATE_COOKIE_MAX_AGE_SECS,
    }),
  );
  headers.set(
    "Location",
    buildGoogleAuthUrl(env, callbackRedirectUri(url, env), state),
  );
  return noindexResponse(null, { status: 302, headers });
}

/** GET /auth/callback — exchanges the code, checks the allowlist, issues the session cookie. */
async function handleAuthCallback(request, env) {
  if (
    !isConfiguredAuthSecret(env.GOOGLE_CLIENT_ID) ||
    !isConfiguredAuthSecret(env.GOOGLE_CLIENT_SECRET) ||
    !isConfiguredAuthSecret(env.SESSION_SECRET)
  ) {
    return noindexResponse("Sign-in is not configured yet", {
      status: 503,
      headers: { "Content-Type": "text/plain" },
    });
  }

  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const returnedState = url.searchParams.get("state");
  const cookies = parseCookies(request);
  const expectedState = cookies[STATE_COOKIE_NAME];

  function failureHeaders(extra) {
    const headers = new Headers(extra);
    headers.append("Set-Cookie", clearCookie(STATE_COOKIE_NAME));
    headers.set("Content-Type", "text/plain");
    return headers;
  }

  if (
    !code ||
    !returnedState ||
    !(
      (expectedState && constantTimeEqual(returnedState, expectedState)) ||
      (await verifyState(returnedState, env.SESSION_SECRET))
    )
  ) {
    // Diagnostic only (#647): the exact reason never reaches the response body or an
    // attacker — just a Slack alert naming which check failed, so the next occurrence is
    // visible without a live wrangler tail.
    const reason = !code
      ? "missing-code"
      : !returnedState
        ? "missing-returned-state"
        : "state-invalid"; // neither the cookie nor the signed state verified
    await captureError(
      { name: `auth-callback-rejected:${reason}` },
      {
        release: env.RELEASE,
        environment: env.ENVIRONMENT,
        route: "/auth/callback",
      },
      env,
    );
    return noindexResponse("Sign-in failed", {
      status: 400,
      headers: failureHeaders(),
    });
  }

  try {
    const tokens = await exchangeCodeForTokens(
      code,
      env,
      callbackRedirectUri(url, env),
    );
    const profile = await fetchGoogleUserinfo(tokens.access_token);
    const email = typeof profile.email === "string" ? profile.email : null;
    const verified =
      profile.email_verified === true || profile.email_verified === "true";

    if (!email || !verified || !isEmailAllowed(email, env.ALLOWED_EMAILS)) {
      return noindexResponse("Not authorized", {
        status: 403,
        headers: failureHeaders(),
      });
    }

    const expiresAt = Math.floor(Date.now() / 1000) + SESSION_MAX_AGE_SECS;
    const sessionValue = await signSession(
      email.trim().toLowerCase(),
      expiresAt,
      env.SESSION_SECRET,
    );

    const headers = new Headers({ Location: "/" });
    headers.append("Set-Cookie", clearCookie(STATE_COOKIE_NAME));
    headers.append(
      "Set-Cookie",
      buildCookie(SESSION_COOKIE_NAME, sessionValue, {
        maxAgeSecs: SESSION_MAX_AGE_SECS,
      }),
    );
    return noindexResponse(null, { status: 302, headers });
  } catch (err) {
    const tags = {
      release: env.RELEASE,
      environment: env.ENVIRONMENT,
      route: "/auth/callback",
    };
    await captureError(err, tags, env);
    return noindexResponse("Sign-in failed", {
      status: 502,
      headers: failureHeaders(),
    });
  }
}

export default {
  /**
   * @param {Request} request
   * @param {{ STATUS: import('./kv-types').KVNamespaceLike, TOKEN_MAC: string, TOKEN_VM: string }} env
   * @param {ExecutionContext} ctx
   * @returns {Promise<Response>}
   */
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/beat") {
      if (request.method !== "POST")
        return noindexResponse(null, { status: 405 });
      return handleBeat(request, env);
    }

    if (url.pathname === "/status.json") {
      if (request.method !== "GET")
        return noindexResponse(null, { status: 405 });
      if (!(await requireSession(request, env))) return redirectTo("/login");
      return handleStatusJson(env);
    }

    if (url.pathname === "/") {
      if (request.method !== "GET")
        return noindexResponse(null, { status: 405 });
      if (!(await requireSession(request, env))) return redirectTo("/login");
      return handleHome(env);
    }

    if (url.pathname === "/pipelines") {
      if (request.method !== "GET")
        return noindexResponse(null, { status: 405 });
      if (!(await requireSession(request, env))) return redirectTo("/login");
      return handlePipelines(env);
    }

    if (url.pathname === "/ci") {
      if (request.method !== "GET")
        return noindexResponse(null, { status: 405 });
      if (!(await requireSession(request, env))) return redirectTo("/login");
      return handleCi(env);
    }

    if (url.pathname === "/sales-agents") {
      if (request.method !== "GET")
        return noindexResponse(null, { status: 405 });
      if (!(await requireSession(request, env))) return redirectTo("/login");
      return handleSalesAgents(env);
    }

    if (url.pathname === "/backlog-priority") {
      if (request.method !== "POST")
        return noindexResponse(null, { status: 405 });
      if (!(await requireSession(request, env))) return redirectTo("/login");
      return handleBacklogPriority(request, env);
    }

    if (url.pathname === "/learnings/push") {
      if (request.method !== "POST")
        return noindexResponse(null, { status: 405 });
      return handleLearningsPush(request, env);
    }

    if (url.pathname === "/learnings") {
      if (request.method !== "GET")
        return noindexResponse(null, { status: 405 });
      if (!(await requireSession(request, env))) return redirectTo("/login");
      return handleLearningsPage(env);
    }

    if (url.pathname === "/learnings/edit") {
      if (request.method !== "POST")
        return noindexResponse(null, { status: 405 });
      if (!(await requireSession(request, env))) return redirectTo("/login");
      return handleLearningsEdit(request, env);
    }

    if (url.pathname === "/learnings/delete") {
      if (request.method !== "POST")
        return noindexResponse(null, { status: 405 });
      if (!(await requireSession(request, env))) return redirectTo("/login");
      return handleLearningsDelete(request, env);
    }

    if (url.pathname === "/login") {
      if (request.method !== "GET")
        return noindexResponse(null, { status: 405 });
      return handleLogin(request, env);
    }

    if (url.pathname === "/auth/callback") {
      if (request.method !== "GET")
        return noindexResponse(null, { status: 405 });
      return handleAuthCallback(request, env);
    }

    if (url.pathname === "/robots.txt") {
      if (request.method !== "GET")
        return noindexResponse(null, { status: 405 });
      return handleRobots();
    }

    return noindexResponse(null, { status: 404 });
  },
};
