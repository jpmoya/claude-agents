// src/index.js — router, bearer auth, rate limiting, response headers.
//
// Routes: POST /beat, GET /status.json, GET /, GET /robots.txt, else 404. X-Robots-Tag: noindex
// is applied in one place to every response. Auth is a pure-JS constant-time compare
// (XOR-accumulate, no early return — crypto.subtle.timingSafeEqual doesn't exist in the Node
// test runtime) against both TOKEN_MAC and TOKEN_VM, with no early exit; the host label is
// whichever secret matched, never read from the body. Rate limiting is a module-scope Map keyed
// by CF-Connecting-IP, fixed 60s window, bounded eviction, reset via __resetRateLimiter for
// vitest. See issue #11 / #4 §5 for the full routes and validation tables.

import { validateBeatPayload } from './validate.js';
import { renderPage } from './render.js';
import { KEEPALIVE_SECS, computeThresholds } from './vocab.js';

const MAX_BEAT_BYTES = 16 * 1024; // 16 KB cap (routes table: "> 16 KB" -> 413)
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
  if (typeof a !== 'string' || typeof b !== 'string') return false;
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
  response.headers.set('X-Robots-Tag', 'noindex');
  return response;
}

function extractBearerToken(request) {
  const header = request.headers.get('Authorization') || '';
  const match = /^Bearer\s+(.+)$/.exec(header);
  return match ? match[1] : null;
}

async function handleBeat(request, env) {
  const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  if (isRateLimited(ip)) return noindexResponse(null, { status: 429 });

  const token = extractBearerToken(request);
  const okMac = constantTimeEqual(token || '', env.TOKEN_MAC || '');
  const okVm = constantTimeEqual(token || '', env.TOKEN_VM || '');
  let host = null;
  if (okMac) host = 'mac';
  else if (okVm) host = 'vm';
  if (!host) return noindexResponse(null, { status: 401 });

  const rawBody = await request.text();
  const byteLength = new TextEncoder().encode(rawBody).length;
  if (byteLength > MAX_BEAT_BYTES) return noindexResponse(null, { status: 413 });

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
  const [macRaw, vmRaw] = await Promise.all([env.STATUS.get('host:mac'), env.STATUS.get('host:vm')]);
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
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'max-age=15' },
  });
}

async function handleHome(env) {
  const hosts = await readHostRecords(env);
  const thresholds = computeThresholds(KEEPALIVE_SECS);
  const nowEpochSecs = Math.floor(Date.now() / 1000);
  const html = renderPage(hosts, thresholds, nowEpochSecs);
  return noindexResponse(html, {
    status: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'max-age=15' },
  });
}

function handleRobots() {
  return noindexResponse('User-agent: *\nDisallow: /\n', {
    status: 200,
    headers: { 'Content-Type': 'text/plain' },
  });
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

    if (url.pathname === '/beat') {
      if (request.method !== 'POST') return noindexResponse(null, { status: 405 });
      return handleBeat(request, env);
    }

    if (url.pathname === '/status.json') {
      if (request.method !== 'GET') return noindexResponse(null, { status: 405 });
      return handleStatusJson(env);
    }

    if (url.pathname === '/') {
      if (request.method !== 'GET') return noindexResponse(null, { status: 405 });
      return handleHome(env);
    }

    if (url.pathname === '/robots.txt') {
      if (request.method !== 'GET') return noindexResponse(null, { status: 405 });
      return handleRobots();
    }

    return noindexResponse(null, { status: 404 });
  },
};
