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
      { name: '[jp] MOCKUPS APPROVED', when: { label: 'UI change: yes' } },
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
      { name: 'promotion', when: { label: 'risky list' } },
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
