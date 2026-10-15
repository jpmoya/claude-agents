// STUB (issue #273) — the fullstack-developer replaces this with the real diagram data.
// Contract (see test/pipelines.test.js):
//   PIPELINES: Array<{ id, title, stages: Array<{ name, when?: { label, coming?: boolean } }> }>
//   findDrift(data, sourceText): string[]  — stage names / non-coming condition labels not in sourceText
export const PIPELINES = [];

export function findDrift(_data, _sourceText) {
  throw new Error('NotImplemented');
}
