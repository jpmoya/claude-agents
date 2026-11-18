// src/sales-agents.js — data for the "Sales Agents" tab.
//
// Informational documentation only: Benji's outbound-sales agent pipeline
// (lead-sourcing-researcher, outbound-sales-writer, partnership-outbound-writer,
// outbound-sequencer, reply-watch) lives in a completely different repo
// (Benjis-Plants/sales-agents) and has nothing to do with the engineering ticket pipeline
// rendered by src/pipelines.js. Nothing here is drift-checked against agents/orchestrator.md,
// agents/product-manager.md or agents/delivery-lead.md — this is free text.
//
// Shape: { sharedAgents: Array<stage>, replyWatch: stage, tracks: Array<{ id, title, pipeline,
// dailyTarget, stages }> }, where `stage` is `{ name, when?: { label, coming? }, inputs: string[] }`
// — the same shape src/pipelines.js uses, so render.js's existing renderNode/renderTrack helpers
// render both tabs with the same UML-style box-and-arrow visual language. `sharedAgents` is a
// sequential pair (sequencer hands off to the researcher when short of volume) so it renders as
// one arrowed row; `replyWatch` runs independently (not triggered by the sequencer) so it renders
// as its own standalone box, not chained into that arrow.
//
// As of 2026-11-11: two tracks share the lead-sourcing and sequencing agents and run daily on
// separate Copper pipelines. `DAILY_CAP_PER_PROSPECT` (how many emails one prospect ever gets)
// is a different number from each track's `dailyTarget` (how many different prospects get
// touched today) — called out as its own stat tile on the page since mixing the two up was a
// real point of confusion for JP.

/** Per-prospect cap: how many emails one prospect ever gets across its whole sequence, never more. */
export const DAILY_CAP_PER_PROSPECT = 3;

/** Starting daily-volume targets are not a ceiling — JP expects to scale here once the team trusts the output. */
export const SCALE_NOTE =
  "These daily targets are a starting point, not a ceiling: JP expects to scale to 10-20/day per track once the team trusts the output.";

export const SALES_AGENTS = {
  sharedAgents: [
    {
      name: "outbound-sequencer",
      inputs: [
        "Checks both Copper pipelines daily (Vancouver Outbound, Preferred Vendor Outreach)",
        "Decides which prospects are due a touch today: day-0 / day-4 / day-11 cadence",
        `Enforces the per-prospect cap of ${DAILY_CAP_PER_PROSPECT} emails total, never more`,
        "Dispatches each due touch to the right track's writer",
      ],
    },
    {
      name: "lead-sourcing-researcher",
      when: { label: "only if a track is short of today's daily target" },
      inputs: [
        "Sources new leads only when a track doesn't have enough due today to hit its daily volume target",
        "Finds personalization vectors per lead: sector/vertical, current competitor, a recent trigger (office move, reno), whether the contact is new in their role, relevant PR/news on return-to-office or workplace experience",
      ],
    },
  ],
  replyWatch: {
    name: "reply-watch",
    when: { label: "scheduled task, twice daily" },
    inputs: [
      "A scheduled task, not a registered agent",
      "Checks both pipelines for a real reply, never an autoreply",
      "Pings JP directly and stops that prospect's sequence on a real reply",
    ],
  },
  tracks: [
    {
      id: "vancouver",
      title: "Vancouver Outbound",
      pipeline: "Vancouver Outbound",
      dailyTarget: "5-7 touches/day",
      stages: [
        {
          name: "outbound-sales-writer",
          inputs: [
            "CRM check in the Vancouver Outbound pipeline",
            "Writes the personalized email",
            "Drafts a LinkedIn connection note",
          ],
        },
        {
          name: "JP review",
          when: { label: "hard approval gate" },
          inputs: [
            "JP reviews the exact drafted text before anything sends",
            "No agent sends on its own",
          ],
        },
        {
          name: "outbound-sales-writer",
          inputs: [
            "Once approved: sends the email and the LinkedIn connection request",
            "Logs the touch in that prospect's own Copper pipeline",
          ],
        },
      ],
    },
    {
      id: "partnership",
      title: "Preferred Vendor Outreach (partnership)",
      pipeline: "Preferred Vendor Outreach",
      dailyTarget: "3 touches/day",
      stages: [
        {
          name: "partnership-outbound-writer",
          inputs: [
            "CRM check in the Preferred Vendor Outreach pipeline",
            "Writes the personalized email",
            "No LinkedIn step yet",
          ],
        },
        {
          name: "JP review",
          when: { label: "hard approval gate" },
          inputs: [
            "JP reviews the exact drafted text before anything sends",
            "No agent sends on its own",
          ],
        },
        {
          name: "partnership-outbound-writer",
          inputs: [
            "Once approved: sends the email",
            "Logs the touch in that prospect's own Copper pipeline",
          ],
        },
      ],
    },
  ],
};
