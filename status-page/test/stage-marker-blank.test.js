// Issue #94 — the page never invents "other": a missing/null/empty stage or marker is stored and
// rendered blank; only a NON-EMPTY value outside the list becomes "other". DEPLOYED TO STAGING is a
// known marker, and every routing marker in hooks/pipeline-markers.sh is in MARKER_VOCAB.
// Expected values come from the ticket text (no code-derived values).

import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { validateBeatPayload } from '../src/validate.js';
import { renderPage } from '../src/render.js';
import { MARKER_VOCAB } from '../src/vocab.js';
import { validPayload, validRun } from './fixtures.js';

const BLANK = ['', null, undefined]; // "stored blank" — never "other"

function runOf(overrides, dropKeys = []) {
  const run = validRun(overrides);
  for (const k of dropKeys) delete run[k];
  const r = validateBeatPayload(validPayload({ runs: [run] }));
  expect(r.ok).toBe(true);
  expect(r.value.runs).toHaveLength(1); // the run survives
  return r.value.runs[0];
}

describe('#94 sanitiseStage — missing / null / empty -> blank, unlisted non-empty -> other', () => {
  it('a missing stage key is blank, not "other"', () => {
    const run = runOf({}, ['stage']);
    expect(BLANK).toContain(run.stage);
    expect(run.stage).not.toBe('other');
  });
  it('a null stage is blank, not "other"', () => {
    const run = runOf({ stage: null });
    expect(BLANK).toContain(run.stage);
  });
  it('an empty-string stage is blank, not "other"', () => {
    const run = runOf({ stage: '' });
    expect(BLANK).toContain(run.stage);
  });
  it('a non-empty unlisted stage is still "other"', () => {
    expect(runOf({ stage: 'code-reviewer-3' }).stage).toBe('other');
  });
  it('a listed stage (including "orchestrator") is kept as itself', () => {
    expect(runOf({ stage: 'orchestrator' }).stage).toBe('orchestrator');
    expect(runOf({ stage: 'deployer' }).stage).toBe('deployer');
  });
});

describe('#94 sanitiseMarker — missing / null / empty -> blank, unlisted non-empty -> other', () => {
  it('a missing marker key is blank, not "other"', () => {
    const run = runOf({}, ['marker']);
    expect(BLANK).toContain(run.marker);
    expect(run.marker).not.toBe('other');
  });
  it('a null marker is blank, not "other"', () => {
    expect(BLANK).toContain(runOf({ marker: null }).marker);
  });
  it('an empty-string marker is blank, not "other"', () => {
    expect(BLANK).toContain(runOf({ marker: '' }).marker);
  });
  it('a non-empty unlisted marker is still "other"', () => {
    expect(runOf({ marker: '[deployer] DEPLOYED' }).marker).toBe('other');
  });
});

describe('#94 rendering — blank stage/marker cells show nothing (no "other", "null", "undefined")', () => {
  it('a run with no stage and no marker renders blank cells', () => {
    const run = runOf({ issue: 4242, stage: null, marker: null });
    const hosts = {
      mac: {
        v: 1,
        received_at: '2026-09-17T18:00:00Z',
        supervisor_last_tick: '2026-09-17T18:00:00Z',
        capacity: { running: 1, max: 3, queued: 0 },
        runs: [run],
      },
      vm: null,
    };
    const html = renderPage(hosts, { staleSecs: 1500, offlineSecs: 4500 }, 0);
    expect(html).toContain('4242'); // control: the run is rendered
    expect(html).not.toContain('other');
    expect(html).not.toContain('undefined');
    expect(html).not.toContain('null');
  });
});

describe('#94 MARKER_VOCAB', () => {
  it('includes DEPLOYED TO STAGING, and such a marker survives on a run as itself', () => {
    expect(MARKER_VOCAB).toContain('DEPLOYED TO STAGING');
    expect(runOf({ marker: 'DEPLOYED TO STAGING' }).marker).toBe('DEPLOYED TO STAGING');
  });

  it('every routing marker in hooks/pipeline-markers.sh (agents other than the human `jp`) is in MARKER_VOCAB', () => {
    const src = readFileSync(new URL('../../hooks/pipeline-markers.sh', import.meta.url), 'utf8');
    const found = [];
    for (const m of src.matchAll(/^\s+([a-z][a-z-]*)\)\s+echo '([^']*)'/gm)) {
      if (m[1] === 'jp') continue; // vocab.js header: all agents except the human jp marker set
      for (const marker of m[2].split('|')) found.push(marker);
    }
    expect(found.length).toBeGreaterThan(20); // control: the parse actually found the list
    const missing = [...new Set(found)].filter((x) => !MARKER_VOCAB.includes(x));
    expect(missing).toEqual([]);
  });
});
