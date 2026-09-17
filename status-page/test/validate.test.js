// AC4 (direct unit tests of the pure validator) + the validation table in issue #11 / #4 §5.
// Expected values are taken verbatim from that table. validateBeatPayload is pure
// (sanitise-by-reconstruction), so these are exercised without going through fetch/KV at all.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { validPayload, validRun } from './fixtures.js';

describe('validateBeatPayload — v field', () => {
  it('accepts v === 1', () => {
    const result = validateBeatPayload(validPayload());
    expect(result.ok).toBe(true);
  });

  it('rejects v !== 1 (400, per routes table "bad JSON, v != 1, > 20 runs")', () => {
    const result = validateBeatPayload(validPayload({ v: 2 }));
    expect(result.ok).toBe(false);
    expect(result.reason).toBe('bad-version');
  });

  it('rejects a missing v', () => {
    const payload = validPayload();
    delete payload.v;
    const result = validateBeatPayload(payload);
    expect(result.ok).toBe(false);
    expect(result.reason).toBe('bad-version');
  });
});

describe('validateBeatPayload — sanitise-by-reconstruction (unknown fields never survive)', () => {
  it('drops a wholly unknown top-level field', () => {
    const result = validateBeatPayload(validPayload({ unknown_field: 'sneaky' }));
    expect(result.ok).toBe(true);
    expect(result.value).not.toHaveProperty('unknown_field');
    expect(JSON.stringify(result.value)).not.toContain('sneaky');
  });

  it('sanitises a payload containing a "sessions" field (frozen v1 has none — AC4)', () => {
    const result = validateBeatPayload(
      validPayload({ sessions: [{ id: 'abc', title: 'leak me' }] })
    );
    expect(result.ok).toBe(true);
    expect(result.value).not.toHaveProperty('sessions');
    expect(JSON.stringify(result.value)).not.toContain('leak me');
  });

  it('drops an unknown field nested inside a run object', () => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ extra: 'nope' })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs[0]).not.toHaveProperty('extra');
  });
});

describe('validateBeatPayload — ISO-8601Z timestamp fields (field dropped on violation)', () => {
  const isoFields = ['sent_at', 'supervisor_last_tick'];

  for (const field of isoFields) {
    it(`drops top-level "${field}" when malformed`, () => {
      const result = validateBeatPayload(validPayload({ [field]: 'not-a-date' }));
      expect(result.ok).toBe(true);
      expect(result.value).not.toHaveProperty(field);
    });

    it(`keeps top-level "${field}" when it matches /^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$/`, () => {
      const result = validateBeatPayload(validPayload({ [field]: '2026-09-17T18:00:00Z' }));
      expect(result.ok).toBe(true);
      expect(result.value[field]).toBe('2026-09-17T18:00:00Z');
    });
  }

  for (const field of ['started_at', 'last_activity_at']) {
    it(`drops run-level "${field}" when malformed, run itself survives`, () => {
      const result = validateBeatPayload(
        validPayload({ runs: [validRun({ [field]: '17 Sept 2026' })] })
      );
      expect(result.ok).toBe(true);
      expect(result.value.runs[0]).not.toHaveProperty(field);
    });
  }
});

describe('validateBeatPayload — capacity.{running,max,queued} (clamped/dropped on violation)', () => {
  it('accepts integers within 0-99', () => {
    const result = validateBeatPayload(
      validPayload({ capacity: { running: 0, max: 99, queued: 5 } })
    );
    expect(result.ok).toBe(true);
    expect(result.value.capacity).toEqual({ running: 0, max: 99, queued: 5 });
  });

  it('clamps capacity.running above 99 to 99', () => {
    const result = validateBeatPayload(
      validPayload({ capacity: { running: 500, max: 99, queued: 0 } })
    );
    expect(result.ok).toBe(true);
    expect(result.value.capacity.running).toBe(99);
  });

  it('clamps a negative capacity value to 0', () => {
    const result = validateBeatPayload(
      validPayload({ capacity: { running: -5, max: 3, queued: 0 } })
    );
    expect(result.ok).toBe(true);
    expect(result.value.capacity.running).toBe(0);
  });
});

describe('validateBeatPayload — runs array length (boundary: 20 ok, 21 rejected)', () => {
  it('accepts exactly 20 runs', () => {
    const runs = Array.from({ length: 20 }, (_, i) => validRun({ issue: i + 1 }));
    const result = validateBeatPayload(validPayload({ runs }));
    expect(result.ok).toBe(true);
    expect(result.value.runs).toHaveLength(20);
  });

  it('rejects 21 runs with 400 (per routes table)', () => {
    const runs = Array.from({ length: 21 }, (_, i) => validRun({ issue: i + 1 }));
    const result = validateBeatPayload(validPayload({ runs }));
    expect(result.ok).toBe(false);
    expect(result.reason).toBe('too-many-runs');
  });
});

describe('validateBeatPayload — runs[].repo (pattern; violation -> "other")', () => {
  it('accepts a valid alias matching /^[a-z0-9][a-z0-9-]{0,23}$/', () => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ repo: 'project-a' })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].repo).toBe('project-a');
  });

  it('sanitises an owner/repo path to "other" (kills the "/")', () => {
    const result = validateBeatPayload(
      validPayload({ runs: [validRun({ repo: 'jpmoya/claude-agents' })] })
    );
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].repo).toBe('other');
  });

  it('sanitises a filesystem path to "other"', () => {
    const result = validateBeatPayload(
      validPayload({ runs: [validRun({ repo: '/etc/passwd' })] })
    );
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].repo).toBe('other');
  });

  it('sanitises a free-text issue title to "other"', () => {
    const result = validateBeatPayload(
      validPayload({ runs: [validRun({ repo: 'fix the login bug for real this time' })] })
    );
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].repo).toBe('other');
  });

  it('sanitises an over-length string (25 chars, one past the 24-char cap) to "other"', () => {
    const tooLong = 'a'.repeat(25);
    const result = validateBeatPayload(validPayload({ runs: [validRun({ repo: tooLong })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].repo).toBe('other');
  });
});

describe('validateBeatPayload — runs[].issue (integer 1-999999; violation -> run dropped)', () => {
  it('accepts issue at the lower boundary (1)', () => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ issue: 1 })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs).toHaveLength(1);
  });

  it('accepts issue at the upper boundary (999999)', () => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ issue: 999999 })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs).toHaveLength(1);
  });

  it('drops the run when issue is 0 (below range)', () => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ issue: 0 })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs).toHaveLength(0);
  });

  it('drops the run when issue is 1000000 (above range)', () => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ issue: 1000000 })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs).toHaveLength(0);
  });

  it('drops the run when issue is not an integer', () => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ issue: 4.5 })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs).toHaveLength(0);
  });
});

describe('validateBeatPayload — runs[].state (enum; violation -> run dropped)', () => {
  it.each(['running', 'restarting', 'queued', 'held'])('accepts state "%s"', (state) => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ state })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs).toHaveLength(1);
    expect(result.value.runs[0].state).toBe(state);
  });

  it('drops the run for an out-of-vocabulary state (e.g. "done", which is explicitly out of scope)', () => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ state: 'done' })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs).toHaveLength(0);
  });
});

describe('validateBeatPayload — runs[].stage (enum; violation -> "other")', () => {
  it('accepts a known agent-roster stage', () => {
    const result = validateBeatPayload(
      validPayload({ runs: [validRun({ stage: 'fullstack-developer' })] })
    );
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].stage).toBe('fullstack-developer');
  });

  it('sanitises an out-of-vocabulary stage to "other" (vocab drift never errors)', () => {
    const result = validateBeatPayload(
      validPayload({ runs: [validRun({ stage: 'not-a-real-agent' })] })
    );
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].stage).toBe('other');
  });
});

describe('validateBeatPayload — runs[].marker (enum; violation -> "other")', () => {
  it('accepts a known marker vocabulary value', () => {
    const result = validateBeatPayload(
      validPayload({ runs: [validRun({ marker: 'TESTS WRITTEN' })] })
    );
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].marker).toBe('TESTS WRITTEN');
  });

  it('sanitises a fabricated log-line-shaped marker to "other"', () => {
    const result = validateBeatPayload(
      validPayload({ runs: [validRun({ marker: '2026-09-17T18:00:00Z ERROR connection reset' })] })
    );
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].marker).toBe('other');
  });
});

describe('validateBeatPayload — runs[].restarts (integer 0-99; violation -> clamped)', () => {
  it('accepts restarts within 0-99', () => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ restarts: 3 })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].restarts).toBe(3);
  });

  it('clamps restarts above 99 to 99', () => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ restarts: 500 })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].restarts).toBe(99);
  });

  it('clamps a negative restarts value to 0', () => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ restarts: -1 })] }));
    expect(result.ok).toBe(true);
    expect(result.value.runs[0].restarts).toBe(0);
  });
});

describe('AC4 — leak test: fake issue title, file path, and log line planted in otherwise-valid fields', () => {
  it('none of the planted strings survive into the validated value', () => {
    const plantedTitle = 'URGENT fix prod outage before demo';
    const plantedPath = '/Users/jp/dev/claude-agents/secrets.env';
    const plantedLogLine = '2026-09-17T18:00:00Z [ERROR] worker crashed, dumping stack';

    const result = validateBeatPayload(
      validPayload({
        runs: [
          validRun({
            repo: plantedTitle, // otherwise-valid field: runs[].repo
            stage: plantedPath, // otherwise-valid field: runs[].stage
            marker: plantedLogLine, // otherwise-valid field: runs[].marker
          }),
        ],
      })
    );

    expect(result.ok).toBe(true);
    const serialised = JSON.stringify(result.value);
    expect(serialised).not.toContain(plantedTitle);
    expect(serialised).not.toContain(plantedPath);
    expect(serialised).not.toContain(plantedLogLine);

    // Positive assertion, not just absence: the run must have survived, sanitised to "other" —
    // not silently dropped, which would make the leak test pass for the wrong reason.
    expect(result.value.runs).toHaveLength(1);
    expect(result.value.runs[0].repo).toBe('other');
    expect(result.value.runs[0].stage).toBe('other');
    expect(result.value.runs[0].marker).toBe('other');
  });
});
