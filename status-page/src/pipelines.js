// src/pipelines.js — single source of truth for the Pipelines tab (one UML-style routing diagram).
//
// Shape: Array<{ id, title, group?: string, summary?: string, stages: Array<{ name, when?: { label, coming?: boolean }, inputs: string[] }> }>.
// Stage names and non-`coming` condition labels must appear verbatim in agents/orchestrator.md,
// agents/product-manager.md or agents/delivery-lead.md; findDrift() and the drift test enforce it.
// A `when` is the GitHub comment-marker / label that routes a ticket into that stage (the same
// vocabulary hooks/pipeline-markers.sh and the agents post to the issue); `coming: true` marks a
// rule that is planned but not live yet. `inputs` are the comment markers / fields the stage reads
// (see "Readiness checks" in agents/orchestrator.md) — free text, not drift-checked.
//
// `group` and `summary` are page-layout-only (not drift-checked, free text): `group` buckets a
// track under one of render.js's TRACK_GROUPS headings ('main' = the ordinary path most tickets
// take, 'special' = a case that only some tickets hit) — a track with no `group`, or an unknown
// one, renders ungrouped. `summary` is the one-line plain-language caption shown under the track's
// heading, above its stage diagram.

export const PIPELINES = [
  {
    id: "code",
    title: "Code ticket (full lane)",
    group: "main",
    summary:
      "The default path for most tickets: design and architecture gates as needed, tests written up front, then the developer implements against them.",
    stages: [
      {
        name: "product-manager",
        inputs: ["JP request or idea", "GitHub issue (title, body)"],
      },
      {
        name: "ux-flow-designer",
        when: { label: "UX flow: yes" },
        inputs: [
          "PM comment: UX flow: yes, UI change: yes",
          "Why, Acceptance Criteria, Files",
        ],
      },
      {
        name: "ui-ux-designer",
        when: { label: "UI change: yes" },
        inputs: [
          "User flow (or PM spec)",
          "Repo design system",
          "Waits for **[jp] MOCKUPS APPROVED**",
        ],
      },
      {
        name: "**[jp] MOCKUPS APPROVED**",
        when: { label: "UI change: yes" },
        inputs: [
          "ui-ux-designer mockups posted on the issue",
          "JP's approval comment",
        ],
      },
      {
        name: "solutions-architect",
        when: { label: "READY FOR ARCHITECTURE" },
        inputs: ["PM comment: READY FOR ARCHITECTURE", "Ticket body"],
      },
      {
        name: "test-writer",
        when: { label: "UI change: no" },
        inputs: [
          "Acceptance Criteria",
          "Approved mockups (UI tickets)",
          "Architecture design (if any)",
        ],
      },
      {
        name: "test-reviewer",
        inputs: [
          "TESTS WRITTEN: Branch, Commit",
          "Locked test files",
          "Acceptance Criteria to test table",
        ],
      },
      { name: "fullstack-developer", inputs: ["TESTS WRITTEN and lock file"] },
      { name: "code-reviewer", inputs: ["IMPLEMENTED: PR, Added test files"] },
      {
        name: "deployer",
        inputs: [
          "code-reviewer PASS",
          "test-reviewer PASS",
          "TESTS APPROVED for the latest commit",
        ],
      },
    ],
  },
  {
    id: "mockup-skip",
    title: "Mockup gate shortcut",
    group: "main",
    summary:
      "Planned shortcut for the full lane above: some tickets will skip the mockup-approval wait and go straight to engineering.",
    stages: [
      {
        name: "product-manager",
        inputs: ["JP request or idea", "GitHub issue (title, body)"],
      },
      {
        name: "fullstack-developer",
        when: { label: "Upfront skip of mockup gate", coming: true },
        inputs: ["READY FOR ENGINEERING with the skip rule (planned)"],
      },
    ],
  },
  {
    id: "fast",
    title: "Fast lane (small fixes)",
    group: "main",
    summary:
      "A shortcut on the path above for small, low-risk fixes: no design or architecture gates, the developer writes one regression test, and it moves fast.",
    stages: [
      {
        name: "product-manager",
        when: { label: "Lane: fast" },
        inputs: ["PM spec: Lane: fast line", "Why, Acceptance Criteria, Files"],
      },
      {
        name: "fullstack-developer",
        inputs: [
          "READY FOR ENGINEERING, Lane: fast",
          "No lock file — writes its own regression test",
        ],
      },
      {
        name: "code-reviewer",
        inputs: ["IMPLEMENTED: PR, Added test files (fast lane)"],
      },
      {
        name: "test-reviewer",
        inputs: ["Narrow review of the added regression test, every round"],
      },
      {
        name: "deployer",
        inputs: ["code-reviewer PASS", "test-reviewer narrow PASS"],
      },
    ],
  },
  {
    id: "lane-rule",
    title: "Lane rule (fast or full)",
    group: "main",
    summary:
      "How product-manager decides, for every ticket, which of the two lanes above it takes.",
    stages: [
      {
        name: "product-manager",
        when: { label: "schema change" },
        inputs: ["Schema change or new endpoint forces Lane: full"],
      },
      {
        name: "fullstack-developer",
        when: { label: "Lane: full" },
        inputs: ["Full lane: locked tests, no own regression test"],
      },
    ],
  },
  {
    id: "infra",
    title: "Infra track",
    group: "special",
    summary:
      "Special case: changes to a live system (DNS, hosting settings, credentials) rather than a feature PR, so it has its own plan-review-run steps instead of the usual tests-and-code-review path.",
    stages: [
      {
        name: "infra-planner",
        when: { label: "infra" },
        inputs: ["Issue labelled infra", "Read-only look at current state"],
      },
      {
        name: "infra-reviewer",
        inputs: [
          "Runbook: command, expected, verify, rollback, environment per step",
        ],
      },
      {
        name: "infra-operator",
        inputs: ["PLAN PASS", "JP go comment for production steps"],
      },
    ],
  },
  {
    id: "incident",
    title: "Incident review (on demand)",
    group: "special",
    summary:
      "Special case: only runs when the pipeline itself misbehaves (a run held, exited or restarted unexpectedly) — never for an ordinary product bug.",
    stages: [
      {
        name: "pipeline-diagnostician",
        inputs: [
          "Incident: run held, exited or restarted unexpectedly",
          "Logs and run state on both hosts",
        ],
      },
      {
        name: "pipeline-adjudicator",
        inputs: [
          "Diagnostician's final report, verbatim",
          "Proposal issue number, if any",
        ],
      },
    ],
  },
  {
    id: "delivery",
    title: "Delivery lead",
    group: "special",
    summary:
      "Special case: an unattended lead that keeps a whole batch of tickets (a milestone, or every open one) moving while JP is away, making the day-to-day calls itself.",
    stages: [
      {
        name: "delivery-lead",
        inputs: [
          "Goal: owner/repo:milestone, milestones:all or a single issue",
          "Ticket markers and PR state",
        ],
      },
    ],
  },
  {
    id: "release",
    title: "Release / promotion",
    group: "special",
    summary:
      "Special case: the final merge-to-production step every ticket ends at, and the one spot where a risky-list change still needs JP's own go-ahead.",
    stages: [
      {
        name: "deployer",
        inputs: ["Both reviewers PASS", "TESTS APPROVED for the latest commit"],
      },
      {
        name: "JP-only",
        when: { label: "risky list" },
        inputs: [
          "Risky-list change (destructive DB change, etc.)",
          "JP's explicit go",
        ],
      },
    ],
  },
];

/**
 * Stage names and non-`coming` condition labels not present verbatim in `sourceText`.
 * @param {Array<object>} data
 * @param {string} sourceText
 * @returns {string[]}
 */
export function findDrift(data, sourceText) {
  const drift = new Set();
  for (const track of data) {
    for (const stage of track.stages) {
      if (!sourceText.includes(stage.name)) drift.add(stage.name);
      const when = stage.when;
      if (when && !when.coming && !sourceText.includes(when.label))
        drift.add(when.label);
    }
  }
  return [...drift];
}
