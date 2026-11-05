// src/auth.js — Google OAuth 2.0 (Authorization Code flow) for the human-facing routes
// (GET /, /status.json, /pipelines). POST /beat's bearer-token auth in index.js is untouched.
//
// Session cookie is a signed `email|expiresAtEpochSecs|hexSignature` string (HMAC-SHA256 over
// `email|expiresAtEpochSecs`, keyed on the SESSION_SECRET Worker secret) — not a JWT, per design.
// Verification uses crypto.subtle.verify (constant-time by spec), not a hand-rolled compare.
//
// No library: Google's Authorization Code flow is three plain HTTP calls (redirect to Google,
// exchange the code at the token endpoint, read the userinfo endpoint) — all reachable with the
// Workers runtime's `fetch` and `crypto.subtle`.

export const GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
export const GOOGLE_USERINFO_URL =
  "https://www.googleapis.com/oauth2/v3/userinfo";

export const SESSION_COOKIE_NAME = "session";
export const SESSION_MAX_AGE_SECS = 30 * 24 * 60 * 60; // 30 days
export const STATE_COOKIE_NAME = "oauth_state";
export const STATE_COOKIE_MAX_AGE_SECS = 10 * 60; // 10 minutes, just long enough for the Google round trip

/** True if `secret` is a real configured value, not a missing/blank binding (mirrors index.js). */
export function isConfiguredSecret(secret) {
  return typeof secret === "string" && secret.length > 0;
}

function toHex(buffer) {
  return [...new Uint8Array(buffer)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function fromHex(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++)
    bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
  return bytes;
}

async function importHmacKey(secret) {
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

/**
 * Signs a session cookie value for `email`, expiring at `expiresAtEpochSecs`.
 * @param {string} email
 * @param {number} expiresAtEpochSecs
 * @param {string} secret
 * @returns {Promise<string>} `email|expiresAtEpochSecs|hexSignature`
 */
export async function signSession(email, expiresAtEpochSecs, secret) {
  const payload = `${email}|${expiresAtEpochSecs}`;
  const key = await importHmacKey(secret);
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(payload),
  );
  return `${payload}|${toHex(sig)}`;
}

/**
 * Verifies a session cookie value. Checks the signature (crypto.subtle.verify — constant time
 * per the Web Crypto spec) and the embedded expiry (not just the cookie's own Max-Age).
 * @param {unknown} cookieValue
 * @param {string} secret
 * @returns {Promise<{ email: string } | null>}
 */
export async function verifySession(cookieValue, secret) {
  if (typeof cookieValue !== "string" || !isConfiguredSecret(secret))
    return null;

  // Emails never contain '|', so splitting on the last two '|' is unambiguous.
  const parts = cookieValue.split("|");
  if (parts.length !== 3) return null;
  const [email, expiresAtStr, sigHex] = parts;
  if (
    !email ||
    !/^[0-9]+$/.test(expiresAtStr) ||
    !/^[0-9a-f]+$/i.test(sigHex) ||
    sigHex.length % 2 !== 0
  ) {
    return null;
  }

  const expiresAt = Number(expiresAtStr);
  if (!Number.isFinite(expiresAt)) return null;

  const key = await importHmacKey(secret);
  const payload = `${email}|${expiresAtStr}`;
  let valid;
  try {
    valid = await crypto.subtle.verify(
      "HMAC",
      key,
      fromHex(sigHex),
      new TextEncoder().encode(payload),
    );
  } catch {
    return null; // malformed hex, odd length, etc.
  }
  if (!valid) return null;

  if (Date.now() / 1000 > expiresAt) return null; // expired, independent of the cookie's own Max-Age

  return { email };
}

/**
 * Parses the `ALLOWED_EMAILS` secret (comma-separated) into a lowercased, trimmed set.
 * An unset or empty value allows nobody — adding a second viewer is a one-line secret edit.
 * @param {unknown} csv
 * @returns {Set<string>}
 */
export function parseAllowedEmails(csv) {
  if (typeof csv !== "string") return new Set();
  return new Set(
    csv
      .split(",")
      .map((e) => e.trim().toLowerCase())
      .filter((e) => e.length > 0),
  );
}

/** @param {unknown} email @param {unknown} allowedEmailsCsv */
export function isEmailAllowed(email, allowedEmailsCsv) {
  if (typeof email !== "string" || email.length === 0) return false;
  return parseAllowedEmails(allowedEmailsCsv).has(email.trim().toLowerCase());
}

/** Parses the `Cookie` request header into a plain name -> value map. */
export function parseCookies(request) {
  const header = request.headers.get("Cookie") || "";
  const out = {};
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq === -1) continue;
    const name = part.slice(0, eq).trim();
    const value = part.slice(eq + 1).trim();
    if (!name) continue;
    try {
      out[name] = decodeURIComponent(value);
    } catch {
      // A malformed %-escape (decodeURIComponent throws URIError) must never crash the request —
      // skip just this one cookie, so an attacker-sent garbage Cookie header still gets a clean
      // 302/noindex from requireSession, not an uncaught-exception 500 with no X-Robots-Tag.
    }
  }
  return out;
}

/** Builds one Set-Cookie header value. */
export function buildCookie(
  name,
  value,
  {
    maxAgeSecs,
    httpOnly = true,
    secure = true,
    sameSite = "Lax",
    path = "/",
  } = {},
) {
  const parts = [
    `${name}=${encodeURIComponent(value)}`,
    `Path=${path}`,
    `SameSite=${sameSite}`,
  ];
  if (httpOnly) parts.push("HttpOnly");
  if (secure) parts.push("Secure");
  if (typeof maxAgeSecs === "number") parts.push(`Max-Age=${maxAgeSecs}`);
  return parts.join("; ");
}

/** A Set-Cookie value that immediately expires `name` (used to clear the short-lived state cookie). */
export function clearCookie(name, { path = "/" } = {}) {
  return `${name}=; Path=${path}; SameSite=Lax; HttpOnly; Secure; Max-Age=0`;
}

/**
 * Reads the session cookie (if any), verifies it, and re-checks the allowlist on every call —
 * so removing an email from ALLOWED_EMAILS revokes an already-issued, still-unexpired cookie
 * immediately, not just on next sign-in.
 * @returns {Promise<string | null>} the authenticated email, or null
 */
export async function requireSession(request, env) {
  if (!isConfiguredSecret(env.SESSION_SECRET)) return null;
  const cookies = parseCookies(request);
  const raw = cookies[SESSION_COOKIE_NAME];
  if (!raw) return null;
  const session = await verifySession(raw, env.SESSION_SECRET);
  if (!session) return null;
  if (!isEmailAllowed(session.email, env.ALLOWED_EMAILS)) return null;
  return session.email;
}

/** Builds the Google authorization URL that /login redirects to. */
export function buildGoogleAuthUrl(env, redirectUri, state) {
  const params = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: "openid email",
    state,
    prompt: "select_account",
  });
  return `${GOOGLE_AUTH_URL}?${params.toString()}`;
}

/** Exchanges an authorization `code` for Google tokens. Throws on a non-2xx response. */
export async function exchangeCodeForTokens(code, env, redirectUri) {
  const res = await fetch(GOOGLE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    }),
  });
  if (!res.ok) throw new Error(`Google token exchange failed: ${res.status}`);
  return res.json();
}

/** Fetches the signed-in user's profile from Google. Throws on a non-2xx response. */
export async function fetchGoogleUserinfo(accessToken) {
  const res = await fetch(GOOGLE_USERINFO_URL, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) throw new Error(`Google userinfo failed: ${res.status}`);
  return res.json();
}
