// src/index.js — router, bearer auth, rate limiting, response headers.
//
// Routes: POST /beat, GET /status.json, GET /, GET /robots.txt, else 404. X-Robots-Tag: noindex
// is applied in one place to every response. Auth is a pure-JS constant-time compare
// (XOR-accumulate, no early return — crypto.subtle.timingSafeEqual doesn't exist in the Node
// test runtime) against both TOKEN_MAC and TOKEN_VM, with no early exit; the host label is
// whichever secret matched, never read from the body. Rate limiting is a module-scope Map keyed
// by CF-Connecting-IP, fixed 60s window, bounded eviction, reset via __resetRateLimiter for
// vitest. See issue #11 / #4 §5 for the full routes and validation tables.
//
// STUB — no branching, no KV access yet. Throws until implemented by the fullstack-developer.

/**
 * Constant-time string compare. No early return on mismatch.
 * @param {string} a
 * @param {string} b
 * @returns {boolean}
 */
export function constantTimeEqual(a, b) {
  throw new Error('NotImplemented');
}

/** Resets the module-scope rate-limit state. Test-only export so vitest cases aren't order-dependent. */
export function __resetRateLimiter() {
  throw new Error('NotImplemented');
}

export default {
  /**
   * @param {Request} request
   * @param {{ STATUS: import('./kv-types').KVNamespaceLike, TOKEN_MAC: string, TOKEN_VM: string }} env
   * @param {ExecutionContext} ctx
   * @returns {Promise<Response>}
   */
  async fetch(request, env, ctx) {
    throw new Error('NotImplemented');
  },
};
