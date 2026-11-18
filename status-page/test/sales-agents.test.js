// Sales Agents tab — GET /sales-agents: documentation-only view of Benji's outbound-sales agent
// pipeline (a separate repo/system from the engineering ticket pipeline on /pipelines). No drift
// check against agents/orchestrator.md etc. applies here — that mechanism is specific to
// src/pipelines.js and does not cover this free-text data.

import { describe, it, expect, beforeEach, vi } from "vitest";

vi.mock("../src/capture.js", () => ({ captureError: vi.fn(async () => {}) }));
vi.mock("../src/render.js", async (importOriginal) => {
  const orig = await importOriginal();
  return { ...orig, renderSalesAgents: vi.fn(orig.renderSalesAgents) };
});

import worker, { __resetRateLimiter } from "../src/index.js";
import * as render from "../src/render.js";
import { captureError as realCaptureError } from "../src/capture.js";
import { SALES_AGENTS, DAILY_CAP_PER_PROSPECT } from "../src/sales-agents.js";
import { createMockKV } from "./mock-kv.js";
import { makeEnv, getRequest } from "./fixtures.js";

beforeEach(() => {
  __resetRateLimiter();
  vi.clearAllMocks();
});

async function getSalesAgents(env = makeEnv()) {
  const res = await worker.fetch(getRequest("/sales-agents"), env, {});
  return { res, html: await res.text() };
}

describe("GET /sales-agents — route", () => {
  it("no session cookie redirects (302) to /login, carrying noindex", async () => {
    const res = await worker.fetch(
      getRequest("/sales-agents", { cookie: null }),
      makeEnv(),
      {},
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("/login");
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
  });

  it("returns 200 text/html with noindex and Cache-Control: max-age=15 when signed in", async () => {
    const { res } = await getSalesAgents();
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toMatch(/text\/html/);
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
    expect(res.headers.get("Cache-Control")).toBe("max-age=15");
  });

  it("POST /sales-agents -> 405 with noindex, same as other routes", async () => {
    const res = await worker.fetch(
      getRequest("/sales-agents", { method: "POST" }),
      makeEnv(),
      {},
    );
    expect(res.status).toBe(405);
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
  });

  it("makes no KV reads or writes (documentation-only, no host data)", async () => {
    const kv = createMockKV();
    const { res, html } = await getSalesAgents(makeEnv({ STATUS: kv }));
    expect(res.status).toBe(200);
    expect(html).toContain("Benji's outbound-sales agents");
    expect(kv._calls()).toEqual({ get: 0, put: 0, delete: 0 });
  });
});

describe("content — agent names, track titles, daily targets vs. per-prospect cap", () => {
  it("names every agent and the reply-watch scheduled task", async () => {
    const { html } = await getSalesAgents();
    for (const name of [
      "lead-sourcing-researcher",
      "outbound-sales-writer",
      "partnership-outbound-writer",
      "outbound-sequencer",
      "reply-watch",
    ]) {
      expect(html, name).toContain(name);
    }
  });

  it("names both track titles", async () => {
    const { html } = await getSalesAgents();
    expect(html).toContain("Vancouver Outbound");
    expect(html).toContain("Preferred Vendor Outreach");
  });

  it("renders the 5-7 and 3 daily-target numbers as stat tiles", async () => {
    const { html } = await getSalesAgents();
    const vancouverTile =
      /<div class="sa-tile"><div class="sa-tile-value">5-7 touches\/day<\/div><div class="sa-tile-label">[^<]*Vancouver Outbound[^<]*<\/div><\/div>/;
    const partnershipTile =
      /<div class="sa-tile"><div class="sa-tile-value">3 touches\/day<\/div><div class="sa-tile-label">[^<]*Preferred Vendor Outreach[^<]*<\/div><\/div>/;
    expect(html).toMatch(vancouverTile);
    expect(html).toMatch(partnershipTile);
  });

  it("mentions the per-prospect cap of 3 in a tile distinctly labelled from the daily targets", async () => {
    const { html } = await getSalesAgents();
    const capTile =
      /<div class="sa-tile"><div class="sa-tile-value">3 emails<\/div><div class="sa-tile-label">[^<]*[Pp]er.?prospect[^<]*<\/div><\/div>/;
    expect(html).toMatch(capTile);
    // the cap tile's own label never says "daily volume target" (that phrase is reserved for the
    // two track tiles), so a reader can't confuse the two numbers.
    const capLabelMatch =
      /<div class="sa-tile-value">3 emails<\/div><div class="sa-tile-label">([^<]*)<\/div>/.exec(
        html,
      );
    expect(capLabelMatch).not.toBeNull();
    expect(capLabelMatch[1]).not.toMatch(/daily volume target/);
  });

  it("the enforced-cap value matches the exported DAILY_CAP_PER_PROSPECT constant", () => {
    expect(DAILY_CAP_PER_PROSPECT).toBe(3);
  });

  it("calls out that daily targets are a starting point, not a ceiling (scale to 10-20/day)", async () => {
    const { html } = await getSalesAgents();
    expect(html).toMatch(/starting point, not a ceiling/);
    expect(html).toMatch(/10-20\/day/);
  });

  it("states the pipeline lives in a different repo and is unrelated to the engineering pipeline", async () => {
    const { html } = await getSalesAgents();
    expect(html).toContain("Benjis-Plants/sales-agents");
    expect(html.toLowerCase()).toContain("different system");
  });

  it("every shared agent and every track stage from SALES_AGENTS renders as a named node", async () => {
    const { html } = await getSalesAgents();
    for (const stage of [
      ...SALES_AGENTS.sharedAgents,
      SALES_AGENTS.replyWatch,
    ]) {
      expect(html, stage.name).toContain(`<b>${stage.name}</b>`);
    }
    for (const track of SALES_AGENTS.tracks) {
      for (const stage of track.stages) {
        expect(html, `${track.id}/${stage.name}`).toContain(
          `<b>${stage.name}</b>`,
        );
      }
    }
  });
});

describe("public-page rules", () => {
  it("has no <script>, no client fetch, no issue/PR numbers, no tokens", async () => {
    const { html } = await getSalesAgents();
    expect(html).not.toMatch(/<script/i);
    expect(html).not.toMatch(/fetch\(/);
    const text = html.replace(/<style[\s\S]*?<\/style>/g, "");
    expect(text).not.toMatch(/\b(ghp_|github_pat_|xox[bp]-|Bearer |TOKEN_)/);
    expect(text).not.toMatch(/(?<!&)#\d+/);
  });

  it("is phone-readable and has light + dark styles", async () => {
    const { html } = await getSalesAgents();
    expect(html).toMatch(/<meta name="viewport"[^>]*width=device-width/);
    expect(html).toMatch(/@media \(prefers-color-scheme: dark\)/);
  });
});

describe("nav — Sales Agents link appears everywhere, marks itself current only on /sales-agents", () => {
  it.each([
    ["/", "Status"],
    ["/pipelines", "Pipelines"],
    ["/ci", "CI"],
    ["/learnings", "Learnings"],
    ["/sales-agents", "Sales Agents"],
  ])(
    "%s shows the Sales Agents link, and marks only %s as current",
    async (path, current) => {
      const res = await worker.fetch(getRequest(path), makeEnv(), {});
      const html = await res.text();
      expect(html).toMatch(
        /<a[^>]*href="\/sales-agents"[^>]*>\s*Sales Agents\s*<\/a>/,
      );
      const marked = [
        ...html.matchAll(
          /<a[^>]*aria-current="page"[^>]*>\s*([^<]+?)\s*<\/a>/g,
        ),
      ].map((m) => m[1]);
      expect(marked).toEqual([current]);
    },
  );
});

describe("observability", () => {
  it("render failure -> 500 + noindex and captureError called with release, environment, route", async () => {
    render.renderSalesAgents.mockImplementationOnce(() => {
      throw new Error("boom");
    });
    const env = makeEnv({ RELEASE: "abc1234def", ENVIRONMENT: "production" });
    const res = await worker.fetch(getRequest("/sales-agents"), env, {});
    expect(res.status).toBe(500);
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
    expect(await res.text()).not.toContain("boom");
    expect(realCaptureError).toHaveBeenCalledTimes(1);
    const [err, tags] = realCaptureError.mock.calls[0];
    expect(err).toBeInstanceOf(Error);
    expect(tags).toMatchObject({
      release: "abc1234def",
      environment: "production",
      route: "/sales-agents",
    });
  });
});
