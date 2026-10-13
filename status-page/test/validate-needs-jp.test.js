// #139 payload — runs[].needs / gate_at / parked_reason: sanitised by reconstruction, unknown values
// dropped (never an error), v stays 1. Expected values from the ticket's Payload section.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { validPayload, validRun } from './fixtures.js';

const runOut = (extra) => {
  const result = validateBeatPayload(validPayload({ runs: [validRun({ state: 'held', marker: 'BLOCKED', ...extra })] }));
  expect(result.ok).toBe(true);
  return result.value.runs[0];
};

describe('#139 runs[].needs', () => {
  it.each(['Approve mockups', 'Say go', 'Approve effort', 'Missing credential', 'Decision needed'])('valid label %s is kept', (needs) => {
    expect(runOut({ needs }).needs).toBe(needs);
  });

  it.each(['<script>', 'say go', 'Free text from a comment', '', 5, null, {}])('invalid needs %j is omitted, run kept', (needs) => {
    const run = runOut({ needs });
    expect(run).not.toHaveProperty('needs');
    expect(run.issue).toBe(42);
  });
});

describe('#139 runs[].parked_reason', () => {
  it.each(['answered', 'out_of_scope'])('valid %s is kept', (parked_reason) => {
    expect(runOut({ parked_reason }).parked_reason).toBe(parked_reason);
  });

  it.each(['bogus', 'stale', '', 1, null])('invalid parked_reason %j is omitted, run kept', (parked_reason) => {
    expect(runOut({ parked_reason })).not.toHaveProperty('parked_reason');
  });
});

describe('#139 runs[].gate_at', () => {
  it('ISO-8601 Z is kept', () => {
    expect(runOut({ gate_at: '2026-09-20T10:00:00Z' }).gate_at).toBe('2026-09-20T10:00:00Z');
  });

  it.each(['yesterday', '2026-09-20', '2026-09-20T10:00:00+02:00', 1790000000, null])('invalid gate_at %j is omitted', (gate_at) => {
    expect(runOut({ gate_at })).not.toHaveProperty('gate_at');
  });
});

describe('#139 compatibility', () => {
  it('a run without any of the three keys validates unchanged (no new keys appear)', () => {
    const run = runOut({});
    for (const k of ['needs', 'gate_at', 'parked_reason']) expect(run).not.toHaveProperty(k);
  });

  it('payload version stays 1', () => {
    expect(validateBeatPayload(validPayload()).value.v).toBe(1);
  });
});
