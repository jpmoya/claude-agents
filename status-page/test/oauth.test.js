// test/oauth.test.js — Google sign-in in front of the human-facing routes (GET /, /status.json,
// /pipelines). POST /beat's bearer-token auth (test/beat.test.js, test/auth.test.js) is
// untouched by this change; see the "still works" describe block at the bottom for the proof.
//
// Session-cookie fixtures (validSessionCookie/expiredSessionCookie/signSessionForTest) sign with
// Node's own `createHmac`, a different implementation path than src/auth.js's crypto.subtle
// signer — see test/fixtures.js — so a bug shared between the fixture and the code under test
// can't hide a broken check.

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import worker, { __resetRateLimiter } from "../src/index.js";
import { createMockKV } from "./mock-kv.js";
import {
  makeEnv,
  getRequest,
  beatRequest,
  validPayload,
  TOKEN_MAC,
  validSessionCookie,
  expiredSessionCookie,
  signSessionForTest,
  ALLOWED_EMAIL,
  SESSION_SECRET,
} from "./fixtures.js";
import {
  signSession,
  verifySession,
  parseAllowedEmails,
  isEmailAllowed,
  parseCookies,
  buildCookie,
  buildGoogleAuthUrl,
} from "../src/auth.js";

beforeEach(() => {
  __resetRateLimiter();
});

const PROTECTED_ROUTES = ["/", "/status.json", "/pipelines"];

describe("redirect-when-unauthenticated", () => {
  it.each(PROTECTED_ROUTES)(
    "GET %s with no session cookie redirects (302) to /login",
    async (path) => {
      const env = makeEnv();
      const res = await worker.fetch(
        getRequest(path, { cookie: null }),
        env,
        {},
      );
      expect(res.status).toBe(302);
      expect(res.headers.get("Location")).toBe("/login");
    },
  );

  it.each(PROTECTED_ROUTES)(
    "GET %s redirect carries X-Robots-Tag: noindex",
    async (path) => {
      const env = makeEnv();
      const res = await worker.fetch(
        getRequest(path, { cookie: null }),
        env,
        {},
      );
      expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
    },
  );

  it("does not touch KV when unauthenticated", async () => {
    const kv = createMockKV();
    const env = makeEnv({ STATUS: kv });
    await worker.fetch(getRequest("/", { cookie: null }), env, {});
    expect(kv._calls().get).toBe(0);
  });
});

describe("valid-session-cookie-passes", () => {
  it.each(PROTECTED_ROUTES)(
    "GET %s with a valid session cookie returns 200",
    async (path) => {
      const env = makeEnv();
      const res = await worker.fetch(getRequest(path), env, {});
      expect(res.status).toBe(200);
    },
  );

  it("allows a second allowlisted email with no code change — just ALLOWED_EMAILS", async () => {
    const env = makeEnv({
      ALLOWED_EMAILS: `${ALLOWED_EMAIL}, second.viewer@example.com`,
    });
    const cookie = validSessionCookie({ email: "second.viewer@example.com" });
    const res = await worker.fetch(getRequest("/", { cookie }), env, {});
    expect(res.status).toBe(200);
  });

  it("allowlist match is case-insensitive and trims whitespace", async () => {
    const env = makeEnv({
      ALLOWED_EMAILS: "  JP@Example.com ,second@example.com",
    });
    const cookie = validSessionCookie({ email: "jp@example.com" });
    const res = await worker.fetch(getRequest("/", { cookie }), env, {});
    expect(res.status).toBe(200);
  });
});

describe("tampered/expired-cookie-rejected", () => {
  it("an expired (but validly signed) cookie redirects to /login", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      getRequest("/", { cookie: expiredSessionCookie() }),
      env,
      {},
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("/login");
  });

  it("a cookie with the email changed after signing (signature no longer matches) is rejected", async () => {
    const env = makeEnv();
    const good = validSessionCookie({ email: "jp@example.com" });
    const [, expiresAt, sig] = good.split("|");
    const tampered = `attacker@example.com|${expiresAt}|${sig}`;
    const res = await worker.fetch(
      getRequest("/", { cookie: tampered }),
      env,
      {},
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("/login");
  });

  it("a cookie with the expiry extended after signing (signature no longer matches) is rejected", async () => {
    const env = makeEnv();
    const good = validSessionCookie({ expiresInSecs: 10 });
    const [email, , sig] = good.split("|");
    const farFuture = Math.floor(Date.now() / 1000) + 999999;
    const tampered = `${email}|${farFuture}|${sig}`;
    const res = await worker.fetch(
      getRequest("/", { cookie: tampered }),
      env,
      {},
    );
    expect(res.status).toBe(302);
  });

  it("a cookie signed with the wrong secret is rejected", async () => {
    const env = makeEnv();
    const cookie = signSessionForTest(
      ALLOWED_EMAIL,
      Math.floor(Date.now() / 1000) + 3600,
      "a-different-secret-entirely",
    );
    const res = await worker.fetch(getRequest("/", { cookie }), env, {});
    expect(res.status).toBe(302);
  });

  it("a garbage cookie value is rejected, not a thrown error", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      getRequest("/", { cookie: "not-a-valid-session-at-all" }),
      env,
      {},
    );
    expect(res.status).toBe(302);
  });

  it("a malformed %-escape in the Cookie header redirects (302) instead of throwing a 500", async () => {
    const env = makeEnv();
    const req = new Request("https://status.example.workers.dev/", {
      headers: {
        "CF-Connecting-IP": "203.0.113.10",
        Cookie: "session=%E0%A4%A", // invalid percent-escape -> decodeURIComponent throws URIError
      },
    });
    const res = await worker.fetch(req, env, {});
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("/login");
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
  });
});

describe("email-not-on-allowlist-rejected", () => {
  it("a validly signed, unexpired cookie for an email not on ALLOWED_EMAILS is rejected", async () => {
    const env = makeEnv({ ALLOWED_EMAILS: ALLOWED_EMAIL });
    const cookie = validSessionCookie({ email: "not-allowed@example.com" });
    const res = await worker.fetch(getRequest("/", { cookie }), env, {});
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("/login");
  });

  it("an empty/unset ALLOWED_EMAILS allows nobody, even the previously-valid email", async () => {
    const env = makeEnv({ ALLOWED_EMAILS: "" });
    const res = await worker.fetch(getRequest("/"), env, {});
    expect(res.status).toBe(302);
  });

  it("removing an email from ALLOWED_EMAILS revokes an already-issued, still-unexpired cookie immediately", async () => {
    const cookie = validSessionCookie({ email: "leaving@example.com" });
    const stillAllowed = makeEnv({ ALLOWED_EMAILS: "leaving@example.com" });
    expect(
      (await worker.fetch(getRequest("/", { cookie }), stillAllowed, {}))
        .status,
    ).toBe(200);

    const nowRevoked = makeEnv({ ALLOWED_EMAILS: ALLOWED_EMAIL }); // same signature, allowlist shrunk
    expect(
      (await worker.fetch(getRequest("/", { cookie }), nowRevoked, {})).status,
    ).toBe(302);
  });
});

describe("/beat still works with no session cookie at all", () => {
  it("a valid bearer-token beat with zero cookies on the request still returns 204", async () => {
    const env = makeEnv();
    const req = new Request("https://status.example.workers.dev/beat", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "CF-Connecting-IP": "203.0.113.10",
        Authorization: `Bearer ${TOKEN_MAC}`,
      },
      body: JSON.stringify(validPayload()),
    });
    expect(req.headers.get("Cookie")).toBeNull();
    const res = await worker.fetch(req, env, {});
    expect(res.status).toBe(204);
  });

  it("/beat is unaffected by SESSION_SECRET/ALLOWED_EMAILS being unset entirely", async () => {
    const env = makeEnv({
      SESSION_SECRET: undefined,
      ALLOWED_EMAILS: undefined,
    });
    const res = await worker.fetch(
      beatRequest({ body: validPayload(), token: TOKEN_MAC }),
      env,
      {},
    );
    expect(res.status).toBe(204);
  });
});

// ---------------------------------------------------------------------------------------------
// GET /login
// ---------------------------------------------------------------------------------------------

describe("GET /login", () => {
  it("redirects (302) to Google with client_id, redirect_uri, response_type=code, scope, state", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      getRequest("/login", { cookie: null }),
      env,
      {},
    );
    expect(res.status).toBe(302);
    const location = new URL(res.headers.get("Location"));
    expect(location.origin + location.pathname).toBe(
      "https://accounts.google.com/o/oauth2/v2/auth",
    );
    expect(location.searchParams.get("client_id")).toBe(env.GOOGLE_CLIENT_ID);
    expect(location.searchParams.get("redirect_uri")).toBe(
      "https://status.example.workers.dev/auth/callback",
    );
    expect(location.searchParams.get("response_type")).toBe("code");
    expect(location.searchParams.get("scope")).toContain("email");
    expect(location.searchParams.get("state")).toBeTruthy();
  });

  it("redirect_uri uses PUBLIC_ORIGIN when set (the Vercel front), not the request origin", async () => {
    const env = { ...makeEnv(), PUBLIC_ORIGIN: "https://pipeline-status-jp.vercel.app/" };
    const res = await worker.fetch(
      getRequest("/login", { cookie: null }),
      env,
      {},
    );
    expect(res.status).toBe(302);
    const location = new URL(res.headers.get("Location"));
    expect(location.searchParams.get("redirect_uri")).toBe(
      "https://pipeline-status-jp.vercel.app/auth/callback",
    );
  });

  it("an empty PUBLIC_ORIGIN falls back to the request origin", async () => {
    const env = { ...makeEnv(), PUBLIC_ORIGIN: "  " };
    const res = await worker.fetch(
      getRequest("/login", { cookie: null }),
      env,
      {},
    );
    const location = new URL(res.headers.get("Location"));
    expect(location.searchParams.get("redirect_uri")).toBe(
      "https://status.example.workers.dev/auth/callback",
    );
  });

  it("sets an httpOnly, Secure, SameSite=Lax state cookie", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      getRequest("/login", { cookie: null }),
      env,
      {},
    );
    const setCookie = res.headers.get("Set-Cookie");
    expect(setCookie).toContain("oauth_state=");
    expect(setCookie).toContain("HttpOnly");
    expect(setCookie).toContain("Secure");
    expect(setCookie).toContain("SameSite=Lax");
  });

  it("carries X-Robots-Tag: noindex", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      getRequest("/login", { cookie: null }),
      env,
      {},
    );
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
  });

  it("returns 405 for POST /login", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      getRequest("/login", { method: "POST", cookie: null }),
      env,
      {},
    );
    expect(res.status).toBe(405);
  });

  it("503s instead of redirecting with an empty client_id when GOOGLE_CLIENT_ID is unset", async () => {
    const env = makeEnv({ GOOGLE_CLIENT_ID: undefined });
    const res = await worker.fetch(
      getRequest("/login", { cookie: null }),
      env,
      {},
    );
    expect(res.status).toBe(503);
  });
});

// ---------------------------------------------------------------------------------------------
// GET /auth/callback
// ---------------------------------------------------------------------------------------------

describe("GET /auth/callback", () => {
  let fetchSpy;
  afterEach(() => fetchSpy && fetchSpy.mockRestore());

  function callbackRequest({
    code = "auth-code-123",
    state = "state-abc",
    stateCookie = "state-abc",
  } = {}) {
    const params = new URLSearchParams();
    if (code !== null) params.set("code", code);
    if (state !== null) params.set("state", state);
    const headers = { "CF-Connecting-IP": "203.0.113.10" };
    if (stateCookie !== null) headers["Cookie"] = `oauth_state=${stateCookie}`;
    return new Request(
      `https://status.example.workers.dev/auth/callback?${params.toString()}`,
      { headers },
    );
  }

  function mockGoogle({ email = ALLOWED_EMAIL, verified = true } = {}) {
    fetchSpy = vi.spyOn(globalThis, "fetch").mockImplementation(async (url) => {
      const href = typeof url === "string" ? url : url.url;
      if (href.startsWith("https://oauth2.googleapis.com/token")) {
        return new Response(
          JSON.stringify({ access_token: "google-access-token" }),
          { status: 200 },
        );
      }
      if (href.startsWith("https://www.googleapis.com/oauth2/v3/userinfo")) {
        return new Response(
          JSON.stringify({ email, email_verified: verified }),
          { status: 200 },
        );
      }
      throw new Error(`unexpected fetch: ${href}`);
    });
  }

  it("a successful sign-in sets the session cookie and redirects to /", async () => {
    mockGoogle({ email: ALLOWED_EMAIL });
    const env = makeEnv();
    const res = await worker.fetch(callbackRequest(), env, {});
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("/");
    const setCookies = res.headers.getSetCookie
      ? res.headers.getSetCookie()
      : [res.headers.get("Set-Cookie")];
    const sessionCookie = setCookies.find((c) => c.startsWith("session="));
    expect(sessionCookie).toBeTruthy();
    expect(sessionCookie).toContain("HttpOnly");
    expect(sessionCookie).toContain("Secure");
  });

  it("the real cookie value /auth/callback issues (not a hand-built fixture) passes the gate on a later GET /", async () => {
    mockGoogle({ email: ALLOWED_EMAIL });
    const env = makeEnv();
    const callbackRes = await worker.fetch(callbackRequest(), env, {});
    const setCookies = callbackRes.headers.getSetCookie
      ? callbackRes.headers.getSetCookie()
      : [callbackRes.headers.get("Set-Cookie")];
    const sessionSetCookie = setCookies.find((c) => c.startsWith("session="));
    const cookiePair = sessionSetCookie.split(";")[0]; // "session=<percent-encoded value>", as a browser would echo it back

    const homeReq = new Request("https://status.example.workers.dev/", {
      headers: { "CF-Connecting-IP": "203.0.113.10", Cookie: cookiePair },
    });
    const homeRes = await worker.fetch(homeReq, env, {});
    expect(homeRes.status).toBe(200);
  });

  it("a mismatched state (CSRF) is rejected with 400 and never calls Google", async () => {
    mockGoogle();
    const env = makeEnv();
    const res = await worker.fetch(
      callbackRequest({ state: "state-abc", stateCookie: "different-state" }),
      env,
      {},
    );
    expect(res.status).toBe(400);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("a missing state cookie (expired/never set) is rejected with 400", async () => {
    mockGoogle();
    const env = makeEnv();
    const res = await worker.fetch(
      callbackRequest({ stateCookie: null }),
      env,
      {},
    );
    expect(res.status).toBe(400);
  });

  it("an email not on the allowlist is rejected with 403 and no session cookie is set", async () => {
    mockGoogle({ email: "not-allowed@example.com" });
    const env = makeEnv({ ALLOWED_EMAILS: ALLOWED_EMAIL });
    const res = await worker.fetch(callbackRequest(), env, {});
    expect(res.status).toBe(403);
    expect(res.headers.get("Set-Cookie")).not.toContain("session=");
  });

  it("email_verified: false from Google is rejected even if the email is on the allowlist", async () => {
    mockGoogle({ email: ALLOWED_EMAIL, verified: false });
    const env = makeEnv();
    const res = await worker.fetch(callbackRequest(), env, {});
    expect(res.status).toBe(403);
  });

  it("a Google token-exchange failure is a clean 502, not a thrown error", async () => {
    fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("error", { status: 400 }));
    const env = makeEnv();
    await expect(
      worker.fetch(callbackRequest(), env, {}),
    ).resolves.toMatchObject({ status: 502 });
  });
});

// ---------------------------------------------------------------------------------------------
// src/auth.js — direct unit tests of the pure/async helpers, per
// skills/quality-gate/SKILL.md ("tested directly even though exercised end to end above").
// ---------------------------------------------------------------------------------------------

describe("signSession / verifySession", () => {
  it("round-trips: a value signed by signSession verifies and returns the email", async () => {
    const expiresAt = Math.floor(Date.now() / 1000) + 60;
    const cookie = await signSession(
      "a@example.com",
      expiresAt,
      SESSION_SECRET,
    );
    const result = await verifySession(cookie, SESSION_SECRET);
    expect(result).toEqual({ email: "a@example.com" });
  });

  it("rejects a cookie signed with a different secret", async () => {
    const expiresAt = Math.floor(Date.now() / 1000) + 60;
    const cookie = await signSession("a@example.com", expiresAt, "secret-one");
    expect(await verifySession(cookie, "secret-two")).toBeNull();
  });

  it("rejects an expired cookie even with a correct signature", async () => {
    const expiresAt = Math.floor(Date.now() / 1000) - 1;
    const cookie = await signSession(
      "a@example.com",
      expiresAt,
      SESSION_SECRET,
    );
    expect(await verifySession(cookie, SESSION_SECRET)).toBeNull();
  });

  it("rejects malformed input instead of throwing", async () => {
    await expect(verifySession("garbage", SESSION_SECRET)).resolves.toBeNull();
    await expect(verifySession("a|b|c|d", SESSION_SECRET)).resolves.toBeNull();
    await expect(verifySession(null, SESSION_SECRET)).resolves.toBeNull();
    await expect(verifySession(undefined, SESSION_SECRET)).resolves.toBeNull();
    await expect(
      verifySession("a@example.com|not-a-number|ab", SESSION_SECRET),
    ).resolves.toBeNull();
    await expect(
      verifySession("a@example.com|123|not-hex!!", SESSION_SECRET),
    ).resolves.toBeNull();
  });

  it("rejects when SESSION_SECRET is not configured", async () => {
    expect(await verifySession("a@example.com|999999999999|aa", "")).toBeNull();
    expect(
      await verifySession("a@example.com|999999999999|aa", undefined),
    ).toBeNull();
  });
});

describe("parseAllowedEmails / isEmailAllowed", () => {
  it("splits on commas, trims, and lowercases", () => {
    expect(parseAllowedEmails(" JP@Example.com , second@EXAMPLE.com ")).toEqual(
      new Set(["jp@example.com", "second@example.com"]),
    );
  });

  it("an unset or empty allowlist is an empty set (allows nobody)", () => {
    expect(parseAllowedEmails(undefined)).toEqual(new Set());
    expect(parseAllowedEmails("")).toEqual(new Set());
  });

  it("isEmailAllowed is case-insensitive and whitespace-tolerant on both sides", () => {
    expect(isEmailAllowed("  JP@EXAMPLE.com", "jp@example.com")).toBe(true);
    expect(isEmailAllowed("nope@example.com", "jp@example.com")).toBe(false);
  });
});

describe("parseCookies", () => {
  it("parses multiple cookies and URL-decodes values", () => {
    const req = new Request("https://x.test/", {
      headers: { Cookie: "a=1; b=hello%20world" },
    });
    expect(parseCookies(req)).toEqual({ a: "1", b: "hello world" });
  });

  it("returns {} when there is no Cookie header", () => {
    const req = new Request("https://x.test/");
    expect(parseCookies(req)).toEqual({});
  });
});

describe("buildCookie / buildGoogleAuthUrl", () => {
  it("buildCookie includes HttpOnly, Secure, SameSite and Max-Age by default", () => {
    const cookie = buildCookie("session", "abc", { maxAgeSecs: 100 });
    expect(cookie).toContain("session=abc");
    expect(cookie).toContain("HttpOnly");
    expect(cookie).toContain("Secure");
    expect(cookie).toContain("SameSite=Lax");
    expect(cookie).toContain("Max-Age=100");
  });

  it('buildGoogleAuthUrl always requests scope "openid email"', () => {
    const url = new URL(
      buildGoogleAuthUrl(
        { GOOGLE_CLIENT_ID: "id-1" },
        "https://x.test/auth/callback",
        "state-1",
      ),
    );
    expect(url.searchParams.get("scope")).toBe("openid email");
  });
});
