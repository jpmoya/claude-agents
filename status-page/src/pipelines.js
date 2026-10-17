// src/pipelines.js — single source of truth for the Pipelines tab (routing diagram).
//
// Shape: Array<{ id, title, stages: Array<{ name, when?: { label, coming?: boolean } }> }>.
// Stage names and non-`coming` condition labels must appear verbatim in agents/orchestrator.md,
// agents/product-manager.md or agents/delivery-lead.md; findDrift() and the drift test enforce it.
// A `when` is the condition that sends a ticket into that stage; `coming: true` marks a rule
// that is planned but not live yet (flip the flag when it lands — no layout code changes).

export const PIPELINES = [
  {
    id: 'code',
    title: 'Code ticket (full lane)',
    stages: [
      { name: 'product-manager' },
      { name: 'ux-flow-designer', when: { label: 'UX flow: yes' } },
      { name: 'ui-ux-designer', when: { label: 'UI change: yes' } },
      { name: '**[jp] MOCKUPS APPROVED**', when: { label: 'UI change: yes' } },
      { name: 'solutions-architect', when: { label: 'READY FOR ARCHITECTURE' } },
      { name: 'test-writer', when: { label: 'UI change: no' } },
      { name: 'test-reviewer' },
      { name: 'fullstack-developer' },
      { name: 'code-reviewer' },
      { name: 'deployer' },
    ],
  },
  {
    id: 'mockup-skip',
    title: 'Mockup gate shortcut',
    stages: [
      { name: 'product-manager' },
      { name: 'fullstack-developer', when: { label: 'Upfront skip of mockup gate', coming: true } },
    ],
  },
  {
    id: 'fast',
    title: 'Fast lane (small fixes)',
    stages: [
      { name: 'product-manager', when: { label: 'Lane: fast' } },
      { name: 'fullstack-developer' },
      { name: 'code-reviewer' },
      { name: 'test-reviewer' },
      { name: 'deployer' },
    ],
  },
  {
    id: 'lane-rule',
    title: 'Lane rule (fast or full)',
    stages: [
      { name: 'product-manager', when: { label: 'schema change' } },
      { name: 'fullstack-developer', when: { label: 'Lane: full' } },
    ],
  },
  {
    id: 'infra',
    title: 'Infra track',
    stages: [
      { name: 'infra-planner', when: { label: 'infra' } },
      { name: 'infra-reviewer' },
      { name: 'infra-operator' },
    ],
  },
  {
    id: 'incident',
    title: 'Incident review (on demand)',
    stages: [{ name: 'pipeline-diagnostician' }, { name: 'pipeline-adjudicator' }],
  },
  {
    id: 'delivery',
    title: 'Delivery lead',
    stages: [{ name: 'delivery-lead' }],
  },
  {
    id: 'release',
    title: 'Release / promotion',
    stages: [
      { name: 'deployer' },
      { name: 'JP-only', when: { label: 'risky list' } },
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

/**
 * Stage inputs for the Pipelines tab diagram (simple UML-style boxes: stage name on top, what it takes in below).
 * Shape: Array<{ id, title, stages: Array<{ name, inputs: string[] }> }>. Each stage box points to the next.
 * Stage names must be agents (agents/<name>.md); inputs are the comment markers / fields the stage reads
 * (see "Readiness checks" in agents/orchestrator.md). Keep in step with PIPELINES above.
 */
export const STAGE_INPUTS = [
  {
    id: 'code',
    title: 'Code ticket: what each stage takes in',
    stages: [
      { name: 'product-manager', inputs: ['JP request or idea', 'GitHub issue (title, body)'] },
      { name: 'ux-flow-designer', inputs: ['PM comment: UX flow: yes, UI change: yes', 'Why, Acceptance Criteria, Files'] },
      { name: 'ui-ux-designer', inputs: ['User flow (or PM spec)', 'Repo design system', 'Waits for **[jp] MOCKUPS APPROVED**'] },
      { name: 'solutions-architect', inputs: ['PM comment: READY FOR ARCHITECTURE', 'Ticket body'] },
      { name: 'test-writer', inputs: ['Acceptance Criteria', 'Approved mockups (UI tickets)', 'Architecture design (if any)'] },
      { name: 'test-reviewer', inputs: ['TESTS WRITTEN: Branch, Commit', 'Locked test files', 'Acceptance Criteria to test table'] },
      { name: 'fullstack-developer', inputs: ['TESTS WRITTEN and lock file', 'Fast lane: PM spec only'] },
      { name: 'code-reviewer', inputs: ['IMPLEMENTED: PR, Added test files'] },
      { name: 'deployer', inputs: ['code-reviewer PASS', 'test-reviewer PASS', 'TESTS APPROVED for the latest commit'] },
    ],
  },
  {
    id: 'infra',
    title: 'Infra track: what each stage takes in',
    stages: [
      { name: 'infra-planner', inputs: ['Issue labelled infra', 'Read-only look at current state'] },
      { name: 'infra-reviewer', inputs: ['Runbook: command, expected, verify, rollback, environment per step'] },
      { name: 'infra-operator', inputs: ['PLAN PASS', 'JP go comment for production steps'] },
    ],
  },
  {
    id: 'delivery',
    title: 'Goals: what the delivery lead takes in',
    stages: [
      { name: 'delivery-lead', inputs: ['Goal: owner/repo:milestone, milestones:all or a single issue', 'Ticket markers and PR state'] },
    ],
  },
];
