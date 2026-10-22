// src/pipelines.js — single source of truth for the Pipelines tab (one UML-style routing diagram).
//
// Shape: Array<{ id, title, stages: Array<{ name, when?: { label, coming?: boolean }, inputs: string[] }> }>.
// Stage names and non-`coming` condition labels must appear verbatim in agents/orchestrator.md,
// agents/product-manager.md or agents/delivery-lead.md; findDrift() and the drift test enforce it.
// A `when` is the GitHub comment-marker / label that routes a ticket into that stage (the same
// vocabulary hooks/pipeline-markers.sh and the agents post to the issue); `coming: true` marks a
// rule that is planned but not live yet. `inputs` are the comment markers / fields the stage reads
// (see "Readiness checks" in agents/orchestrator.md) — free text, not drift-checked.

export const PIPELINES = [
  {
    id: 'code',
    title: 'Code ticket (full lane)',
    stages: [
      { name: 'product-manager', inputs: ['JP request or idea', 'GitHub issue (title, body)'] },
      {
        name: 'ux-flow-designer',
        when: { label: 'UX flow: yes' },
        inputs: ['PM comment: UX flow: yes, UI change: yes', 'Why, Acceptance Criteria, Files'],
      },
      {
        name: 'ui-ux-designer',
        when: { label: 'UI change: yes' },
        inputs: ['User flow (or PM spec)', 'Repo design system', 'Waits for **[jp] MOCKUPS APPROVED**'],
      },
      {
        name: '**[jp] MOCKUPS APPROVED**',
        when: { label: 'UI change: yes' },
        inputs: ['ui-ux-designer mockups posted on the issue', "JP's approval comment"],
      },
      {
        name: 'solutions-architect',
        when: { label: 'READY FOR ARCHITECTURE' },
        inputs: ['PM comment: READY FOR ARCHITECTURE', 'Ticket body'],
      },
      {
        name: 'test-writer',
        when: { label: 'UI change: no' },
        inputs: ['Acceptance Criteria', 'Approved mockups (UI tickets)', 'Architecture design (if any)'],
      },
      { name: 'test-reviewer', inputs: ['TESTS WRITTEN: Branch, Commit', 'Locked test files', 'Acceptance Criteria to test table'] },
      { name: 'fullstack-developer', inputs: ['TESTS WRITTEN and lock file'] },
      { name: 'code-reviewer', inputs: ['IMPLEMENTED: PR, Added test files'] },
      { name: 'deployer', inputs: ['code-reviewer PASS', 'test-reviewer PASS', 'TESTS APPROVED for the latest commit'] },
    ],
  },
  {
    id: 'mockup-skip',
    title: 'Mockup gate shortcut',
    stages: [
      { name: 'product-manager', inputs: ['JP request or idea', 'GitHub issue (title, body)'] },
      {
        name: 'fullstack-developer',
        when: { label: 'Upfront skip of mockup gate', coming: true },
        inputs: ['READY FOR ENGINEERING with the skip rule (planned)'],
      },
    ],
  },
  {
    id: 'fast',
    title: 'Fast lane (small fixes)',
    stages: [
      { name: 'product-manager', when: { label: 'Lane: fast' }, inputs: ['PM spec: Lane: fast line', 'Why, Acceptance Criteria, Files'] },
      { name: 'fullstack-developer', inputs: ['READY FOR ENGINEERING, Lane: fast', 'No lock file — writes its own regression test'] },
      { name: 'code-reviewer', inputs: ['IMPLEMENTED: PR, Added test files (fast lane)'] },
      { name: 'test-reviewer', inputs: ['Narrow review of the added regression test, every round'] },
      { name: 'deployer', inputs: ['code-reviewer PASS', 'test-reviewer narrow PASS'] },
    ],
  },
  {
    id: 'lane-rule',
    title: 'Lane rule (fast or full)',
    stages: [
      { name: 'product-manager', when: { label: 'schema change' }, inputs: ['Schema change or new endpoint forces Lane: full'] },
      { name: 'fullstack-developer', when: { label: 'Lane: full' }, inputs: ['Full lane: locked tests, no own regression test'] },
    ],
  },
  {
    id: 'infra',
    title: 'Infra track',
    stages: [
      { name: 'infra-planner', when: { label: 'infra' }, inputs: ['Issue labelled infra', 'Read-only look at current state'] },
      { name: 'infra-reviewer', inputs: ['Runbook: command, expected, verify, rollback, environment per step'] },
      { name: 'infra-operator', inputs: ['PLAN PASS', 'JP go comment for production steps'] },
    ],
  },
  {
    id: 'incident',
    title: 'Incident review (on demand)',
    stages: [
      { name: 'pipeline-diagnostician', inputs: ['Incident: run held, exited or restarted unexpectedly', 'Logs and run state on both hosts'] },
      { name: 'pipeline-adjudicator', inputs: ["Diagnostician's final report, verbatim", 'Proposal issue number, if any'] },
    ],
  },
  {
    id: 'delivery',
    title: 'Delivery lead',
    stages: [
      {
        name: 'delivery-lead',
        inputs: ['Goal: owner/repo:milestone, milestones:all or a single issue', 'Ticket markers and PR state'],
      },
    ],
  },
  {
    id: 'release',
    title: 'Release / promotion',
    stages: [
      { name: 'deployer', inputs: ['Both reviewers PASS', 'TESTS APPROVED for the latest commit'] },
      {
        name: 'JP-only',
        when: { label: 'risky list' },
        inputs: ['Risky-list change (destructive DB change, etc.)', "JP's explicit go"],
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
      if (when && !when.coming && !sourceText.includes(when.label)) drift.add(when.label);
    }
  }
  return [...drift];
}
