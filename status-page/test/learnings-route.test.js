// POST /learnings/push, GET /learnings, POST /learnings/edit, POST /learnings/delete — the
// Learnings tab's route wiring. Push reuses /beat's bearer auth (TOKEN_MAC/TOKEN_VM) and rate
// limiter; the other three reuse the same session-cookie gate as /, /pipelines, /backlog-priority.

import { describe, it, expect, beforeEach } from "vitest";
import worker, { __resetRateLimiter } from "../src/index.js";
import { createMockKV } from "./mock-kv.js";
import {
  makeEnv,
  getRequest,
  validSessionCookie,
  TOKEN_MAC,
  TOKEN_VM,
} from "./fixtures.js";

const LEARNINGS_KEY = "learnings:entries";

beforeEach(() => {
  __resetRateLimiter();
});

function pushRequest({
  body,
  token = TOKEN_MAC,
  ip = "203.0.113.10",
  headers = {},
} = {}) {
  const h = new Headers({
    "CF-Connecting-IP": ip,
    "Content-Type": "text/plain",
    ...headers,
  });
  if (token !== null) h.set("Authorization", `Bearer ${token}`);
  return new Request("https://status.example.workers.dev/learnings/push", {
    method: "POST",
    headers: h,
    body,
  });
}

function formRequest(
  path,
  { fields = {}, cookie = validSessionCookie() } = {},
) {
  const params = new URLSearchParams(fields);
  const headers = {
    "CF-Connecting-IP": "203.0.113.10",
    "Content-Type": "application/x-www-form-urlencoded",
  };
  if (cookie) headers["Cookie"] = `session=${cookie}`;
  return new Request(`https://status.example.workers.dev${path}`, {
    method: "POST",
    headers,
    body: params.toString(),
  });
}

describe("POST /learnings/push", () => {
  it("401s with no Authorization header, and changes nothing", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      pushRequest({ body: "- a lesson", token: null }),
      env,
      {},
    );
    expect(res.status).toBe(401);
    expect(env.STATUS._calls().put).toBe(0);
  });

  it("401s with a bad token", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      pushRequest({ body: "- a lesson", token: "not-real" }),
      env,
      {},
    );
    expect(res.status).toBe(401);
  });

  it("a session cookie alone (no bearer token) cannot push", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      pushRequest({
        body: "- a lesson",
        token: null,
        headers: { Cookie: `session=${validSessionCookie()}` },
      }),
      env,
      {},
    );
    expect(res.status).toBe(401);
  });

  it("accepts a valid TOKEN_MAC, parses bullets, and stores them in KV", async () => {
    const env = makeEnv();
    const body =
      "# Message triage learnings\n- First lesson\n- Second lesson\n";
    const res = await worker.fetch(
      pushRequest({ body, token: TOKEN_MAC }),
      env,
      {},
    );
    expect(res.status).toBe(204);
    const stored = JSON.parse(env.STATUS._dump()[LEARNINGS_KEY]);
    expect(stored.entries.map((e) => e.text)).toEqual([
      "First lesson",
      "Second lesson",
    ]);
  });

  it("accepts a valid TOKEN_VM too", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      pushRequest({ body: "- a lesson", token: TOKEN_VM }),
      env,
      {},
    );
    expect(res.status).toBe(204);
  });

  it("pushing the same content twice does not duplicate entries", async () => {
    const env = makeEnv();
    const body = "- First lesson\n";
    await worker.fetch(pushRequest({ body, token: TOKEN_MAC }), env, {});
    await worker.fetch(pushRequest({ body, token: TOKEN_MAC }), env, {});
    const stored = JSON.parse(env.STATUS._dump()[LEARNINGS_KEY]);
    expect(stored.entries).toHaveLength(1);
  });

  it("pushing the same content twice only writes to KV once (write-budget AC12)", async () => {
    const env = makeEnv();
    const body = "- First lesson\n";
    await worker.fetch(pushRequest({ body, token: TOKEN_MAC }), env, {});
    expect(env.STATUS._calls().put).toBe(1);
    await worker.fetch(pushRequest({ body, token: TOKEN_MAC }), env, {});
    expect(env.STATUS._calls().put).toBe(1);
  });

  it("a push after a browser delete does not bring the entry back", async () => {
    const env = makeEnv();
    const body = "- First lesson\n- Second lesson\n";
    await worker.fetch(pushRequest({ body, token: TOKEN_MAC }), env, {});
    const stored = JSON.parse(env.STATUS._dump()[LEARNINGS_KEY]);
    const id = stored.entries.find((e) => e.text === "First lesson").id;
    await worker.fetch(
      formRequest("/learnings/delete", { fields: { id } }),
      env,
      {},
    );

    await worker.fetch(
      pushRequest({ body: body + "- Third lesson\n", token: TOKEN_MAC }),
      env,
      {},
    );
    const after = JSON.parse(env.STATUS._dump()[LEARNINGS_KEY]);
    expect(after.entries.map((e) => e.text)).toEqual([
      "Second lesson",
      "Third lesson",
    ]);
  });

  it("413s a body over the cap, and changes nothing", async () => {
    const env = makeEnv();
    const big = "- " + "x".repeat(64 * 1024 + 1);
    const res = await worker.fetch(
      pushRequest({ body: big, token: TOKEN_MAC }),
      env,
      {},
    );
    expect(res.status).toBe(413);
    expect(env.STATUS._calls().put).toBe(0);
  });

  it("returns 405 for GET", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      new Request("https://status.example.workers.dev/learnings/push", {
        method: "GET",
      }),
      env,
      {},
    );
    expect(res.status).toBe(405);
  });

  it("carries X-Robots-Tag: noindex", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      pushRequest({ body: "- a lesson", token: TOKEN_MAC }),
      env,
      {},
    );
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
  });
});

describe("GET /learnings", () => {
  it("requires sign-in: no session cookie redirects to /login", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      getRequest("/learnings", { cookie: null }),
      env,
      {},
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("/login");
  });

  it("a bearer token alone (no session cookie) is still redirected to /login", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      new Request("https://status.example.workers.dev/learnings", {
        method: "GET",
        headers: { Authorization: `Bearer ${TOKEN_MAC}` },
      }),
      env,
      {},
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("/login");
  });

  it("renders the stored entries when signed in", async () => {
    const kv = createMockKV({
      [LEARNINGS_KEY]: JSON.stringify({
        entries: [
          {
            id: "a1",
            text: "Send the actual PDFs",
            added_at: "2026-01-01T00:00:00Z",
          },
        ],
        seen: ["Send the actual PDFs"],
      }),
    });
    const env = makeEnv({ STATUS: kv });
    const res = await worker.fetch(getRequest("/learnings"), env, {});
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("Send the actual PDFs");
    expect(html).toContain("/learnings/edit");
    expect(html).toContain("/learnings/delete");
  });

  it("renders an empty state when nothing has been pushed yet", async () => {
    const env = makeEnv();
    const res = await worker.fetch(getRequest("/learnings"), env, {});
    expect(await res.text()).toContain("no learnings pushed yet");
  });

  it("is never cached (Cache-Control: no-store)", async () => {
    const env = makeEnv();
    const res = await worker.fetch(getRequest("/learnings"), env, {});
    expect(res.headers.get("Cache-Control")).toBe("no-store");
  });

  it("500 is not reachable here, but 405 is for POST", async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      new Request("https://status.example.workers.dev/learnings", {
        method: "POST",
      }),
      env,
      {},
    );
    expect(res.status).toBe(405);
  });
});

describe("POST /learnings/edit", () => {
  function seeded(env0) {
    const kv = createMockKV({
      [LEARNINGS_KEY]: JSON.stringify({
        entries: [
          { id: "a1", text: "old text", added_at: "2026-01-01T00:00:00Z" },
        ],
        seen: ["old text"],
      }),
    });
    return makeEnv({ STATUS: kv, ...env0 });
  }

  it("requires sign-in: no session cookie redirects to /login", async () => {
    const env = seeded();
    const res = await worker.fetch(
      formRequest("/learnings/edit", {
        fields: { id: "a1", text: "x" },
        cookie: null,
      }),
      env,
      {},
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("/login");
  });

  it("a bearer token alone cannot edit", async () => {
    const env = seeded();
    const req = new Request(
      "https://status.example.workers.dev/learnings/edit",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${TOKEN_MAC}`,
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: "id=a1&text=x",
      },
    );
    const res = await worker.fetch(req, env, {});
    expect(res.status).toBe(302);
  });

  it("400s when id is missing", async () => {
    const env = seeded();
    const res = await worker.fetch(
      formRequest("/learnings/edit", { fields: { text: "x" } }),
      env,
      {},
    );
    expect(res.status).toBe(400);
  });

  it("404s for an unknown id", async () => {
    const env = seeded();
    const res = await worker.fetch(
      formRequest("/learnings/edit", { fields: { id: "missing", text: "x" } }),
      env,
      {},
    );
    expect(res.status).toBe(404);
  });

  it("400s when the new text is blank", async () => {
    const env = seeded();
    const res = await worker.fetch(
      formRequest("/learnings/edit", { fields: { id: "a1", text: "   " } }),
      env,
      {},
    );
    expect(res.status).toBe(400);
  });

  it("updates the entry and redirects (303) to /learnings", async () => {
    const env = seeded();
    const res = await worker.fetch(
      formRequest("/learnings/edit", {
        fields: { id: "a1", text: "new text" },
      }),
      env,
      {},
    );
    expect(res.status).toBe(303);
    expect(res.headers.get("Location")).toBe("/learnings");
    const stored = JSON.parse(env.STATUS._dump()[LEARNINGS_KEY]);
    expect(stored.entries[0].text).toBe("new text");
    // seen keeps the original pushed line so a re-push of the Mac file can't duplicate it
    expect(stored.seen).toEqual(["old text"]);
  });
});

describe("POST /learnings/delete", () => {
  function seeded() {
    const kv = createMockKV({
      [LEARNINGS_KEY]: JSON.stringify({
        entries: [
          { id: "a1", text: "old text", added_at: "2026-01-01T00:00:00Z" },
        ],
        seen: ["old text"],
      }),
    });
    return makeEnv({ STATUS: kv });
  }

  it("requires sign-in: no session cookie redirects to /login", async () => {
    const env = seeded();
    const res = await worker.fetch(
      formRequest("/learnings/delete", { fields: { id: "a1" }, cookie: null }),
      env,
      {},
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("/login");
  });

  it("400s when id is missing", async () => {
    const env = seeded();
    const res = await worker.fetch(
      formRequest("/learnings/delete", { fields: {} }),
      env,
      {},
    );
    expect(res.status).toBe(400);
  });

  it("404s for an unknown id", async () => {
    const env = seeded();
    const res = await worker.fetch(
      formRequest("/learnings/delete", { fields: { id: "missing" } }),
      env,
      {},
    );
    expect(res.status).toBe(404);
  });

  it("removes the entry and redirects (303) to /learnings, keeping seen", async () => {
    const env = seeded();
    const res = await worker.fetch(
      formRequest("/learnings/delete", { fields: { id: "a1" } }),
      env,
      {},
    );
    expect(res.status).toBe(303);
    expect(res.headers.get("Location")).toBe("/learnings");
    const stored = JSON.parse(env.STATUS._dump()[LEARNINGS_KEY]);
    expect(stored.entries).toEqual([]);
    expect(stored.seen).toEqual(["old text"]);
  });
});

describe("nav", () => {
  it("Learnings link appears on / and /pipelines, and /learnings marks itself current", async () => {
    const env = makeEnv();
    for (const path of ["/", "/pipelines", "/learnings"]) {
      const res = await worker.fetch(getRequest(path), env, {});
      const html = await res.text();
      expect(html).toMatch(
        /<a[^>]*href="\/learnings"[^>]*>\s*Learnings\s*<\/a>/,
      );
    }
    const res = await worker.fetch(getRequest("/learnings"), env, {});
    const html = await res.text();
    const marked = [
      ...html.matchAll(/<a[^>]*aria-current="page"[^>]*>\s*([A-Za-z]+)/g),
    ].map((m) => m[1]);
    expect(marked).toEqual(["Learnings"]);
  });
});
