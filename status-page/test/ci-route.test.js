// Issue #649 — new GET /ci tab: route/auth/nav wiring, the moved tiles+chart panel, and the new
// per-runner table (name, three-state status, 24h/72h utilization, prod-deploy distinction).
// Expected values are hand-computed from the fixtures below, never copied from src/.

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

vi.mock("../src/capture.js", () => ({ captureError: vi.fn(async () => {}) }));
vi.mock("../src/render.js", async (importOriginal) => {
  const orig = await importOriginal();
  return { ...orig, renderCiPage: vi.fn(orig.renderCiPage) };
});

import worker, { __resetRateLimiter } from "../src/index.js";
import * as render from "../src/render.js";
import { captureError as realCaptureError } from "../src/capture.js";
import { createMockKV } from "./mock-kv.js";
import {
  makeEnv,
  getRequest,
  beatRequest,
  validPayload,
  TOKEN_MAC,
  hostRecord,
  validCiQueue,
  validCiQueueRunner,
  validCiQueueWithRunners,
} from "./fixtures.js";

beforeEach(() => {
  __resetRateLimiter();
  vi.clearAllMocks();
});

async function getCi(env = makeEnv()) {
  const res = await worker.fetch(getRequest("/ci"), env, {});
  return { res, html: await res.text() };
}

describe("GET /ci — route (AC4)", () => {
  it("returns 200 text/html with noindex when signed in", async () => {
    const { res, html } = await getCi();
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toMatch(/text\/html/);
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
    expect(html).toContain("<h1>CI queue</h1>");
  });

  it("no session cookie redirects (302) to /login, carrying noindex", async () => {
    const res = await worker.fetch(getRequest("/ci", { cookie: null }), makeEnv(), {});
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("/login");
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
  });

  it("POST /ci -> 405 with noindex", async () => {
    const res = await worker.fetch(getRequest("/ci", { method: "POST" }), makeEnv(), {});
    expect(res.status).toBe(405);
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
  });

  it("carries the same PAGE_REFRESH_SECS auto-refresh meta tag as the rest of the page", async () => {
    const { html } = await getCi();
    expect(html).toMatch(new RegExp(`<meta http-equiv="refresh" content="${render.PAGE_REFRESH_SECS}">`));
  });
});

describe("nav (AC5) — CI link appears everywhere, marks itself current only on /ci", () => {
  it.each([
    ["/", "Status"],
    ["/pipelines", "Pipelines"],
    ["/ci", "CI"],
    ["/learnings", "Learnings"],
  ])("%s shows the CI link, and marks only %s as current", async (path, current) => {
    const res = await worker.fetch(getRequest(path), makeEnv(), {});
    const html = await res.text();
    expect(html).toMatch(/<a[^>]*href="\/ci"[^>]*>\s*CI\s*<\/a>/);
    const marked = [
      ...html.matchAll(/<a[^>]*aria-current="page"[^>]*>\s*([A-Za-z]+)/g),
    ].map((m) => m[1]);
    expect(marked).toEqual([current]);
  });
});

describe("AC7 — /ci contains the stat tiles + bar chart and the new per-runner table", () => {
  it("renders tiles, chart and runner table together", async () => {
    const mac = hostRecord({
      received_at: "2026-09-21T11:59:00Z",
      ci_queue: validCiQueueWithRunners({
        runners: [validCiQueueRunner({ id: 1 }), validCiQueueRunner({ id: 2, online: false })],
      }),
    });
    const env = makeEnv({ STATUS: createMockKV({ "host:mac": JSON.stringify(mac) }) });
    const { html } = await getCi(env);
    expect(html).toContain("ci-tiles");
    expect(html).toContain("<svg");
    expect(html).toContain('class="group ci-runners"');
  });
});

describe("AC8 — per-runner table: three states, null utilization renders —", () => {
  it("one online+busy (util 87), one offline (util null), one online+idle render three correct rows", async () => {
    const runners = [
      validCiQueueRunner({ id: 1, name: "runner-busy", online: true, busy: true, util_24h_pct: 87, util_72h_pct: 60 }),
      validCiQueueRunner({ id: 2, name: "runner-offline", online: false, busy: false, util_24h_pct: null, util_72h_pct: null }),
      validCiQueueRunner({ id: 3, name: "runner-idle", online: true, busy: false, util_24h_pct: 12, util_72h_pct: 9 }),
    ];
    const mac = hostRecord({
      received_at: "2026-09-21T11:59:00Z",
      ci_queue: validCiQueueWithRunners({ runners }),
    });
    const env = makeEnv({ STATUS: createMockKV({ "host:mac": JSON.stringify(mac) }) });
    const { html } = await getCi(env);

    expect(html).toMatch(/runner-busy[\s\S]{0,200}badge live[\s\S]{0,40}busy[\s\S]{0,80}87%[\s\S]{0,40}60%/);
    expect(html).toMatch(/runner-offline[\s\S]{0,200}badge offline[\s\S]{0,40}offline[\s\S]{0,80}&mdash;[\s\S]{0,40}&mdash;/);
    expect(html).toMatch(/runner-idle[\s\S]{0,200}badge nodata[\s\S]{0,40}idle[\s\S]{0,80}12%[\s\S]{0,40}9%/);
  });

  it("util_24h_pct: 0 renders 0%, not the — fallback (=== null check, not falsy)", async () => {
    const mac = hostRecord({
      received_at: "2026-09-21T11:59:00Z",
      ci_queue: validCiQueueWithRunners({
        runners: [validCiQueueRunner({ util_24h_pct: 0, util_72h_pct: 0 })],
      }),
    });
    const env = makeEnv({ STATUS: createMockKV({ "host:mac": JSON.stringify(mac) }) });
    const { html } = await getCi(env);
    expect(html).toContain("0%");
  });

  it("offline (online: false) always wins over busy: never shown as the busy state", async () => {
    const mac = hostRecord({
      received_at: "2026-09-21T11:59:00Z",
      ci_queue: validCiQueueWithRunners({
        runners: [validCiQueueRunner({ name: "dropped-runner", online: false, busy: true })],
      }),
    });
    const env = makeEnv({ STATUS: createMockKV({ "host:mac": JSON.stringify(mac) }) });
    const { html } = await getCi(env);
    expect(html).toMatch(/dropped-runner[\s\S]{0,200}badge offline[\s\S]{0,40}offline/);
    expect(html).not.toMatch(/dropped-runner[\s\S]{0,200}badge live/);
  });
});

describe("prod-deploy role is visually distinguished (JP: 'unmistakable at a glance')", () => {
  it("a prod_deploy-role runner's row carries a distinct class and badge the general pool never gets", async () => {
    const mac = hostRecord({
      received_at: "2026-09-21T11:59:00Z",
      ci_queue: validCiQueueWithRunners({
        runners: [
          validCiQueueRunner({ id: 1, name: "general-runner", role: "general" }),
          validCiQueueRunner({ id: 2, name: "prod-runner", role: "prod_deploy" }),
        ],
      }),
    });
    const env = makeEnv({ STATUS: createMockKV({ "host:mac": JSON.stringify(mac) }) });
    const { html } = await getCi(env);
    expect(html).toMatch(/<tr class="ci-runner-prod">[\s\S]{0,200}prod-runner/);
    expect(html).toContain("Prod deploy");
    // the general row never carries the prod class/badge
    expect(html).not.toMatch(/<tr class="ci-runner-prod">[\s\S]{0,200}general-runner/);
  });
});

describe("AC9 — graceful degradation, never a 500, never broken/empty table markup", () => {
  it("no ci_queue at all: 200, nav renders, neutral empty-state text, no table", async () => {
    const env = makeEnv();
    const { res, html } = await getCi(env);
    expect(res.status).toBe(200);
    expect(html).toMatch(/<nav[\s\S]*CI[\s\S]*<\/nav>/);
    expect(html).toContain("no CI queue data yet");
    expect(html).not.toContain('class="group ci-runners"');
  });

  it("ci_queue present but runners[] absent (pre-#648 collector): tiles render, no runner table, no error", async () => {
    const mac = hostRecord({ received_at: "2026-09-21T11:59:00Z", ci_queue: validCiQueue() });
    const env = makeEnv({ STATUS: createMockKV({ "host:mac": JSON.stringify(mac) }) });
    const { res, html } = await getCi(env);
    expect(res.status).toBe(200);
    expect(html).toContain("ci-tiles");
    expect(html).not.toContain('class="group ci-runners"');
  });

  it("ci_queue present with an empty runners[]: tiles render, no runner table, no error", async () => {
    const mac = hostRecord({
      received_at: "2026-09-21T11:59:00Z",
      ci_queue: validCiQueueWithRunners({ runners: [] }),
    });
    const env = makeEnv({ STATUS: createMockKV({ "host:mac": JSON.stringify(mac) }) });
    const { res, html } = await getCi(env);
    expect(res.status).toBe(200);
    expect(html).not.toContain('class="group ci-runners"');
  });
});

describe("stale as_of still shows the badge on /ci (same ~15 min threshold as before)", () => {
  it("a ci_queue with an as_of older than staleSecs shows the stale badge", async () => {
    const old = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString(); // 2h old, well past 1500s
    const mac = hostRecord({ received_at: "2026-09-21T11:59:00Z", ci_queue: validCiQueue({ as_of: old }) });
    const env = makeEnv({ STATUS: createMockKV({ "host:mac": JSON.stringify(mac) }) });
    const { html } = await getCi(env);
    expect(html).toMatch(/badge stale/);
  });
});

describe("observability — Sentry route tag for /ci is '/ci'", () => {
  it("render failure -> 500 + noindex and captureError called with release, environment, route: /ci", async () => {
    render.renderCiPage.mockImplementationOnce(() => {
      throw new Error("boom");
    });
    const env = makeEnv({ RELEASE: "abc1234def", ENVIRONMENT: "production" });
    const res = await worker.fetch(getRequest("/ci"), env, {});
    expect(res.status).toBe(500);
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
    expect(await res.text()).not.toContain("boom");
    expect(realCaptureError).toHaveBeenCalledTimes(1);
    const [err, tags] = realCaptureError.mock.calls[0];
    expect(err).toBeInstanceOf(Error);
    expect(tags).toMatchObject({
      release: "abc1234def",
      environment: "production",
      route: "/ci",
    });
  });
});

describe("existing routes unaffected by the new /ci route", () => {
  it("GET / still works and no longer contains the CI panel or runner table markup", async () => {
    const mac = hostRecord({
      received_at: "2026-09-21T11:59:00Z",
      ci_queue: validCiQueueWithRunners(),
    });
    const env = makeEnv({ STATUS: createMockKV({ "host:mac": JSON.stringify(mac) }) });
    const res = await worker.fetch(getRequest("/"), env, {});
    const html = await res.text();
    expect(res.status).toBe(200);
    expect(html).not.toContain("ci-tiles");
    expect(html).not.toContain('class="group ci-runners"');
  });

  it("beat -> /status.json round-trip is untouched by the new route", async () => {
    const env = makeEnv();
    const beatRes = await worker.fetch(
      beatRequest({ token: TOKEN_MAC, body: validPayload({ ci_queue: validCiQueueWithRunners() }) }),
      env,
      {},
    );
    expect(beatRes.status).toBe(204);
    const res = await worker.fetch(getRequest("/status.json"), env, {});
    const json = await res.json();
    expect(json.hosts.mac.ci_queue.runners).toHaveLength(1);
  });
});
