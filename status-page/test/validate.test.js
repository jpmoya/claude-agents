// AC4 (direct unit tests of the pure validator) + the validation table in issue #11 / #4 §5.
// Expected values are taken verbatim from that table. validateBeatPayload is pure
// (sanitise-by-reconstruction), so these are exercised without going through fetch/KV at all.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { isIssueUrl } from '../src/validate.js'; // issue #29
import { readFileSync } from 'node:fs';
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

  // Parameterized across all three capacity fields (test-reviewer finding 3, first round: only
  // `running` was exercised for clamping; `max` and `queued` share the same "integer 0-99,
  // clamped" rule per the validation table and must be proven independently, not assumed.
  it.each(['running', 'max', 'queued'])('clamps capacity.%s above 99 to 99', (field) => {
    const base = { running: 1, max: 3, queued: 0 };
    const result = validateBeatPayload(validPayload({ capacity: { ...base, [field]: 500 } }));
    expect(result.ok).toBe(true);
    expect(result.value.capacity[field]).toBe(99);
  });

  it.each(['running', 'max', 'queued'])('clamps a negative capacity.%s to 0', (field) => {
    const base = { running: 1, max: 3, queued: 0 };
    const result = validateBeatPayload(validPayload({ capacity: { ...base, [field]: -5 } }));
    expect(result.ok).toBe(true);
    expect(result.value.capacity[field]).toBe(0);
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

  // test-reviewer finding 3, first round: the "array" half of "runs | array, length <= 20 | 400"
  // was never exercised, only the length half. Not pinning `result.reason` here: the stub's
  // JSDoc union (src/validate.js) freezes only 'bad-json'|'bad-version'|'too-many-runs', and
  // nothing in the ticket or design names a fourth reason string for a non-array `runs` — that
  // would be inventing a value with no source. `ok: false` is the observable outcome the
  // validation table actually specifies.
  it('rejects a non-array runs value (violates the "array" part of the rule)', () => {
    const result = validateBeatPayload(validPayload({ runs: 'not-an-array' }));
    expect(result.ok).toBe(false);
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

// ---- Issue #29: optional runs[].title / runs[].url (additive v1) -------------------------------
// Expected values come from the ticket's design decision 5 and its "Test fixtures" list.

const GOOD_URL = 'https://github.com/example-owner/project-a/issues/42';
const BAD_URLS = [
  ['javascript: scheme', 'javascript:alert(1)'],
  ['foreign host', 'https://evil.example/example-owner/project-a/issues/42'],
  ['http not https', 'http://github.com/example-owner/project-a/issues/42'],
  ['query string', 'https://github.com/example-owner/project-a/issues/42?x=1'],
  ['pull, not issue', 'https://github.com/example-owner/project-a/pull/42'],
  ['attribute-breakout', 'https://github.com/example-owner/project-a/issues/42" onclick="x'],
  ['non-string number', 42],
];

function keptRun(runOverrides) {
  const result = validateBeatPayload(validPayload({ runs: [validRun(runOverrides)] }));
  expect(result.ok).toBe(true);
  expect(result.value.runs).toHaveLength(1); // the run is never dropped because of title/url
  return result.value.runs[0];
}

describe('isIssueUrl — strict https://github.com/<owner>/<repo>/issues/<n> check (#29 design 5)', () => {
  it.each([
    ['plain', GOOD_URL],
    ['dots, hyphens, underscores in owner/repo', 'https://github.com/a.b-c/d_e.f/issues/1'],
    ['large issue number', 'https://github.com/o/r/issues/999999'],
  ])('accepts %s', (_label, url) => {
    expect(isIssueUrl(url)).toBe(true);
  });

  it.each(BAD_URLS)('rejects %s', (_label, url) => {
    expect(isIssueUrl(url)).toBe(false);
  });

  it.each([
    ['null', null],
    ['undefined', undefined],
    ['empty string', ''],
    ['object', {}],
    ['trailing newline', `${GOOD_URL}\n`],
    ['no issue number', 'https://github.com/o/r/issues/'],
    ['non-numeric issue', 'https://github.com/o/r/issues/abc'],
    ['extra path segment', 'https://github.com/o/r/issues/42/extra'],
  ])('rejects %s', (_label, url) => {
    expect(isIssueUrl(url)).toBe(false);
  });
});

describe('validateBeatPayload — runs[].url (#29 AC5)', () => {
  it('keeps a valid issue url', () => {
    expect(keptRun({ url: GOOD_URL }).url).toBe(GOOD_URL);
  });

  it.each(BAD_URLS)('drops a bad url (%s) but keeps the run and its title', (_label, url) => {
    const run = keptRun({ title: 'Fix login redirect', url });
    expect(run).not.toHaveProperty('url');
    expect(run.title).toBe('Fix login redirect');
  });

  it('keeps a valid url even when there is no title (fields are independent)', () => {
    const run = keptRun({ url: GOOD_URL });
    expect(run.url).toBe(GOOD_URL);
    expect(run).not.toHaveProperty('title');
  });
});

describe('validateBeatPayload — runs[].title (#29 AC6)', () => {
  it('keeps a valid title and url together', () => {
    const run = keptRun({ title: 'Fix login redirect', url: GOOD_URL });
    expect(run.title).toBe('Fix login redirect');
    expect(run.url).toBe(GOOD_URL);
  });

  it.each([
    ['number', 123],
    ['null', null],
    ['object', {}],
    ['array', ['x']],
    ['empty string', ''],
    ['whitespace only', '   '],
    ['control chars only', '\u0000\u0007\u001f\u007f'],
  ])('omits a %s title, keeps the run (and its independently valid url)', (_label, title) => {
    // The valid url is a positive control: it proves title/url handling exists at all, so the
    // omission below is a real sanitisation decision rather than "the field is never emitted".
    const run = keptRun({ title, url: GOOD_URL });
    expect(run.url).toBe(GOOD_URL);
    expect(run).not.toHaveProperty('title');
  });

  it('caps a 200-char title at exactly 140 characters', () => {
    expect(keptRun({ title: 'a'.repeat(200) }).title).toBe('a'.repeat(140));
  });

  it.each([
    [139, 139],
    [140, 140], // the cap itself is not "over"
    [141, 140],
  ])('boundary: a %i-char title comes out %i chars', (inLen, outLen) => {
    expect(keptRun({ title: 'a'.repeat(inLen) }).title).toHaveLength(outLen);
  });

  it('caps by code point, not UTF-16 unit (141 emoji -> 140 emoji, none split)', () => {
    const out = keptRun({ title: '😀'.repeat(141) }).title;
    expect(Array.from(out)).toHaveLength(140);
    expect(out).toBe('😀'.repeat(140));
  });

  it('collapses newlines and tabs to single spaces: "line1\\nline2\\ttab" -> "line1 line2 tab"', () => {
    expect(keptRun({ title: 'line1\nline2\ttab' }).title).toBe('line1 line2 tab');
  });

  it('collapses a run of whitespace/control chars to one space and trims the ends', () => {
    expect(keptRun({ title: '  \u0007spaced \r\n \u0000\u0001 out  ' }).title).toBe('spaced out');
  });

  it('does not strip markup — escaping is the renderer\'s job, the string is kept as text', () => {
    const t = '<script>alert(1)</script> & "quotes"';
    expect(keptRun({ title: t }).title).toBe(t);
  });
});

describe('validateBeatPayload — legacy runs without title/url (#29 AC7)', () => {
  it('a run with neither field validates and stores neither key (a titled run beside it is unaffected)', () => {
    const result = validateBeatPayload(
      validPayload({ runs: [validRun(), validRun({ issue: 43, title: 'Fix login redirect', url: GOOD_URL })] })
    );
    expect(result.ok).toBe(true);
    const [legacy, titled] = result.value.runs;
    expect(titled.title).toBe('Fix login redirect'); // control: the feature exists
    expect(legacy).not.toHaveProperty('title');
    expect(legacy).not.toHaveProperty('url');
    // the existing field set is unchanged
    expect(legacy.repo).toBe('project-a');
    expect(legacy.issue).toBe(42);
  });
});

describe('validate.js header documents the single free-text exception (#29 design 5)', () => {
  it('the header comment (before the first import) names runs[].title as the one documented exception', () => {
    const src = readFileSync(new URL('../src/validate.js', import.meta.url), 'utf8');
    const header = src.slice(0, src.indexOf('import '));
    expect(header).toContain('runs[].title');
  });
});

// ---------------------------------------------------------------------------------------------
// Issue #51 — completed[] (Expected Behavior 6). Every case pairs its "bad" input with a valid
// control item in the same array, so a validator that simply ignores `completed` fails each one.
// ---------------------------------------------------------------------------------------------
import { validCompleted } from './fixtures.js';

describe('validateBeatPayload — completed[] (issue #51)', () => {
  const control = () => validCompleted({ issue: 7, title: 'Control ticket', url: 'https://github.com/example-owner/project-a/issues/7' });
  const completedOf = (items) => {
    const result = validateBeatPayload(validPayload({ completed: items }));
    expect(result.ok).toBe(true); // never a 400
    return result.value.completed;
  };

  it('keeps a valid item with all six fields', () => {
    expect(completedOf([validCompleted()])).toEqual([validCompleted()]);
  });

  it('optional fields may be absent: an item with only repo/issue/closed_at is kept without title/url/marker', () => {
    const out = completedOf([{ repo: 'project-a', issue: 9, closed_at: '2026-09-17T18:00:00Z' }]);
    expect(out).toEqual([{ repo: 'project-a', issue: 9, closed_at: '2026-09-17T18:00:00Z' }]);
  });

  it('drops an item with a missing closed_at (required), keeps the control', () => {
    const bad = validCompleted({ issue: 8 });
    delete bad.closed_at;
    expect(completedOf([bad, control()]).map((c) => c.issue)).toEqual([7]);
  });

  it.each([
    ['"yesterday"', 'yesterday'],
    ['a date without Z', '2026-09-17T18:00:00'],
    ['an offset instead of Z', '2026-09-17T18:00:00+02:00'],
    ['a non-string', 1758132000],
  ])('drops an item whose closed_at is %s', (_label, closedAt) => {
    expect(completedOf([validCompleted({ issue: 8, closed_at: closedAt }), control()]).map((c) => c.issue)).toEqual([7]);
  });

  it.each([
    ['0', 0],
    ['1000000', 1000000],
    ['a string', '42'],
    ['a float', 4.5],
    ['missing', undefined],
  ])('drops an item whose issue is %s', (_label, issue) => {
    expect(completedOf([validCompleted({ issue }), control()]).map((c) => c.issue)).toEqual([7]);
  });

  it('accepts the issue bounds 1 and 999999', () => {
    expect(completedOf([validCompleted({ issue: 1 }), validCompleted({ issue: 999999 })]).map((c) => c.issue)).toEqual([1, 999999]);
  });

  it('drops non-object items', () => {
    expect(completedOf(['x', null, 5, [], control()]).map((c) => c.issue)).toEqual([7]);
  });

  it('a url that is not a GitHub issue URL is removed, the item survives', () => {
    const out = completedOf([validCompleted({ issue: 8, url: 'https://evil.example/x' }), control()]);
    expect(out.map((c) => c.issue)).toEqual([8, 7]);
    expect(out[0]).not.toHaveProperty('url');
    expect(out[1].url).toBe('https://github.com/example-owner/project-a/issues/7');
  });

  it('title goes through the same sanitiser as runs: control/whitespace runs collapsed, capped at 140 code points', () => {
    const out = completedOf([
      validCompleted({ issue: 8, title: 'a\n\t  b' }),
      validCompleted({ issue: 9, title: 'x'.repeat(141) }),
      validCompleted({ issue: 10, title: '   ' }),
    ]);
    expect(out.map((c) => c.issue)).toEqual([8, 9, 10]);
    expect(out[0].title).toBe('a b');
    expect(out[1].title).toBe('x'.repeat(140));
    expect(out[2]).not.toHaveProperty('title'); // empty after sanitising -> omitted, item kept
  });

  it('a <script> title is kept as inert text (escaping happens at render), never as markup-bearing extra fields', () => {
    const out = completedOf([validCompleted({ issue: 8, title: '<script>alert(1)</script>' }), control()]);
    expect(out.map((c) => c.issue)).toEqual([8, 7]);
    expect(out[0].title).toBe('<script>alert(1)</script>');
  });

  it('repo is an alias-or-"other"', () => {
    const out = completedOf([validCompleted({ issue: 8, repo: 'Bad Repo!/x' }), validCompleted({ issue: 9, repo: 'project-b' })]);
    expect(out.map((c) => c.repo)).toEqual(['other', 'project-b']);
  });

  it('marker is enum-or-"other", and stays absent when not sent', () => {
    const noMarker = validCompleted({ issue: 10 });
    delete noMarker.marker;
    const out = completedOf([
      validCompleted({ issue: 8, marker: 'READY FOR ENGINEERING' }),
      validCompleted({ issue: 9, marker: 'rm -rf /' }),
      noMarker,
    ]);
    expect(out[0].marker).toBe('READY FOR ENGINEERING');
    expect(out[1].marker).toBe('other');
    expect(out[2]).not.toHaveProperty('marker');
  });

  it('drops unknown keys inside an item and at top level', () => {
    const result = validateBeatPayload(
      validPayload({ completed: [{ ...validCompleted(), sessions: [{ id: 'leak' }], extra: 'nope' }], sessions: [{ id: 'leak2' }] })
    );
    expect(result.ok).toBe(true);
    expect(result.value.completed).toEqual([validCompleted()]);
    expect(result.value).not.toHaveProperty('sessions');
    expect(JSON.stringify(result.value)).not.toContain('leak');
  });

  it('more than 10 items -> the first 10 are kept, no rejection', () => {
    const items = Array.from({ length: 11 }, (_v, i) => validCompleted({ issue: i + 1 }));
    const out = completedOf(items);
    expect(out.map((c) => c.issue)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  });

  it('exactly 10 items are all kept', () => {
    const items = Array.from({ length: 10 }, (_v, i) => validCompleted({ issue: i + 1 }));
    expect(completedOf(items)).toHaveLength(10);
  });

  it('a non-array completed becomes [] (present, empty) and is not an error', () => {
    for (const bad of ['x', 5, { a: 1 }, null]) {
      const result = validateBeatPayload(validPayload({ completed: bad }));
      expect(result.ok).toBe(true);
      expect(result.value.completed).toEqual([]);
    }
  });

  it('runs are unaffected by a completed key', () => {
    const result = validateBeatPayload(validPayload({ completed: [validCompleted()] }));
    expect(result.value.runs).toHaveLength(1);
    expect(result.value.completed).toHaveLength(1);
  });
});

// ---------------------------------------------------------------------------------------------
// Issue #62 — staging[] / approved[] / completed[].release / new markers. Expected values are
// hand-written from the ticket's Expected Behavior and negative fixtures.
// ---------------------------------------------------------------------------------------------
import { validStagingItem, validApprovedItem } from './fixtures.js';
import { MARKER_VOCAB as MARKERS_62 } from '../src/vocab.js';

describe('validateBeatPayload — staging[] / approved[] (#62 AC1)', () => {
  const run = (extra) => validateBeatPayload(validPayload(extra));
  const items = (key, list) => {
    const r = run({ [key]: list });
    expect(r.ok).toBe(true);
    return r.value[key];
  };

  for (const [key, build] of [['staging', validStagingItem], ['approved', validApprovedItem]]) {
    describe(key, () => {
      it('keeps a valid item unchanged', () => {
        expect(items(key, [build()])).toEqual([build()]);
      });

      it('absent -> [] and accepted', () => {
        const r = validateBeatPayload(validPayload());
        expect(r.ok).toBe(true);
        expect(r.value[key]).toEqual([]);
      });

      it.each([['a string', 'x'], ['an object', {}], ['null', null], ['a number', 5]])('%s -> [] and accepted, never a rejection', (_n, bad) => {
        expect(items(key, bad)).toEqual([]);
      });

      it.each([['issue 0', { issue: 0 }], ['issue "12"', { issue: '12' }], ['issue 1000000', { issue: 1000000 }]])('drops an item with %s, keeps siblings', (_n, bad) => {
        const out = items(key, [build(bad), build({ issue: 99 })]);
        expect(out.map((i) => i.issue)).toEqual([99]);
      });

      it('accepts issue boundaries 1 and 999999', () => {
        expect(items(key, [build({ issue: 1 }), build({ issue: 999999 })]).map((i) => i.issue)).toEqual([1, 999999]);
      });

      it('drops a non-object item, keeps siblings', () => {
        expect(items(key, ['str', 5, null, [], build({ issue: 99 })]).map((i) => i.issue)).toEqual([99]);
      });

      it('omits a non-ISO updated_at but keeps the item', () => {
        const out = items(key, [build({ updated_at: 'yesterday' })]);
        expect(out).toHaveLength(1);
        expect(out[0]).not.toHaveProperty('updated_at');
      });

      it('omits a non-issue url (javascript:) but keeps the item and title', () => {
        const out = items(key, [build({ url: 'javascript:alert(1)' })]);
        expect(out).toHaveLength(1);
        expect(out[0]).not.toHaveProperty('url');
        expect(out[0].title).toBe(build().title);
      });

      it('drops unknown keys on an item (sanitise by reconstruction)', () => {
        const out = items(key, [build({ evil: 'x', sessions: [1] })]);
        expect(out[0]).not.toHaveProperty('evil');
        expect(out[0]).not.toHaveProperty('sessions');
      });
    });
  }

  it('staging: 61 valid items -> the first 60 kept', () => {
    const list = Array.from({ length: 61 }, (_v, i) => validStagingItem({ issue: i + 1 }));
    const out = items('staging', list);
    expect(out).toHaveLength(60);
    expect(out[0].issue).toBe(1);
    expect(out[59].issue).toBe(60);
  });

  it('staging: exactly 60 valid items -> all 60 kept', () => {
    expect(items('staging', Array.from({ length: 60 }, (_v, i) => validStagingItem({ issue: i + 1 })))).toHaveLength(60);
  });

  it('approved: 21 valid items -> the first 20 kept', () => {
    const list = Array.from({ length: 21 }, (_v, i) => validApprovedItem({ issue: i + 1 }));
    const out = items('approved', list);
    expect(out).toHaveLength(20);
    expect(out[19].issue).toBe(20);
  });

  it('cap counts VALID items: 5 invalid then 60 valid staging items -> 60 kept', () => {
    const list = [...Array.from({ length: 5 }, () => validStagingItem({ issue: 0 })), ...Array.from({ length: 60 }, (_v, i) => validStagingItem({ issue: i + 1 }))];
    expect(items('staging', list)).toHaveLength(60);
  });

  it('20 runs are still the run cap and 21 still rejects (unchanged)', () => {
    const r = validateBeatPayload(validPayload({ runs: Array.from({ length: 21 }, (_v, i) => validRun({ issue: i + 1 })) }));
    expect(r.ok).toBe(false);
  });
});

describe('validateBeatPayload — completed[].release (#62 AC1)', () => {
  const releaseOf = (release) => {
    const r = validateBeatPayload(validPayload({ completed: [validCompleted({ release })] }));
    expect(r.ok).toBe(true);
    expect(r.value.completed).toHaveLength(1);
    return r.value.completed[0];
  };

  it.each(['v1.3.0', 'v0.0.1', 'v10.20.30'])('keeps release %s', (rel) => {
    expect(releaseOf(rel).release).toBe(rel);
  });

  it.each(['v1.3', '1.3.0', 'v1.3.0<script>', 'v1.3.0\n', ' v1.3.0', 'v1.3.0-rc1', 5, null, {}])('omits release %j but keeps the item', (rel) => {
    expect(releaseOf(rel)).not.toHaveProperty('release');
  });
});

describe('validateBeatPayload — DECISION / JP CONFIRMED markers (#62 AC2)', () => {
  it.each(['DECISION', 'JP CONFIRMED'])('%s is in MARKER_VOCAB and survives on a run as itself', (m) => {
    expect(MARKERS_62).toContain(m);
    const r = validateBeatPayload(validPayload({ runs: [validRun({ marker: m })] }));
    expect(r.value.runs[0].marker).toBe(m);
  });

  it('survives on completed[].marker too', () => {
    const r = validateBeatPayload(validPayload({ completed: [validCompleted({ marker: 'DECISION' })] }));
    expect(r.value.completed[0].marker).toBe('DECISION');
  });

  it('an unknown marker still degrades to other (control)', () => {
    const r = validateBeatPayload(validPayload({ runs: [validRun({ marker: 'DECISIONS' })] }));
    expect(r.value.runs[0].marker).toBe('other');
  });
});
