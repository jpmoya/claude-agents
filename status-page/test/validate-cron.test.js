// Issue #756 AC7 — cron[] sanitised by reconstruction in validateBeatPayload. Every rule has a case,
// and the "bad" input is always paired with a valid control item so a validator that ignores `cron`
// (or passes it through) fails each one. Expected values are written by hand from the ticket.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { validPayload } from './fixtures.js';

function cronItem(overrides = {}) {
  return {
    name: 'layoff-scan-cron',
    schedule: '0 13 * * 1',
    schedule_human: 'Mondays at 13:00',
    last_run: '2026-11-17T13:00:02Z',
    last_result: 'ok',
    next_run: '2026-11-24T12:00:00Z',
    ...overrides,
  };
}

function cronOf(cron) {
  const result = validateBeatPayload(validPayload({ cron }));
  expect(result.ok).toBe(true); // never a 400
  return result.value.cron;
}

describe('validateBeatPayload — cron[] (issue #756)', () => {
  it('a payload without cron stays valid and carries no cron key', () => {
    const result = validateBeatPayload(validPayload());
    expect(result.ok).toBe(true);
    expect('cron' in result.value).toBe(false);
  });

  it('a valid item survives unchanged', () => {
    expect(cronOf([cronItem()])).toEqual([cronItem()]);
  });

  it('a non-array cron becomes []', () => {
    expect(cronOf('nope')).toEqual([]);
    expect(cronOf({ name: 'x' })).toEqual([]);
    expect(cronOf(null)).toEqual([]);
  });

  it('keeps the first 50 items and drops the rest', () => {
    const items = Array.from({ length: 60 }, (_, i) => cronItem({ name: `job${i + 1}` }));
    const out = cronOf(items);
    expect(out).toHaveLength(50);
    expect(out[0].name).toBe('job1');
    expect(out[49].name).toBe('job50');
  });

  it('drops unknown keys, including a command that must never be stored', () => {
    const out = cronOf([cronItem({ command: 'curl -H token', env: { A: 'b' }, extra: 1 })]);
    expect(out).toEqual([cronItem()]);
    expect(JSON.stringify(out)).not.toContain('curl');
    expect(JSON.stringify(out)).not.toContain('token');
  });

  it('never spreads the input: a __proto__ key does not leak onto the item', () => {
    const raw = JSON.parse('[{"name":"a","schedule":"* * * * *","__proto__":{"polluted":true}}]');
    const out = cronOf(raw);
    expect(out[0].polluted).toBeUndefined();
    expect(Object.keys(out[0]).sort()).toEqual(
      ['last_result', 'last_run', 'name', 'next_run', 'schedule', 'schedule_human'],
    );
  });

  describe('name', () => {
    it('is trimmed', () => {
      expect(cronOf([cronItem({ name: '  tick  ' })])[0].name).toBe('tick');
    });

    it('is capped at 80 characters', () => {
      expect(cronOf([cronItem({ name: 'a'.repeat(120) })])[0].name).toBe('a'.repeat(80));
    });

    it('allows only [A-Za-z0-9._-]: any other character drops the item', () => {
      const bad = ['<script>x</script>', 'has space', 'a/b', 'semi;colon', 'quo"te', 'ünï', ''];
      for (const name of bad) {
        expect(cronOf([cronItem({ name }), cronItem({ name: 'control' })]).map((c) => c.name)).toEqual(['control']);
      }
    });

    it('a non-string name drops the item', () => {
      const out = cronOf([cronItem({ name: 5 }), cronItem({ name: null }), cronItem({ name: ['a'] }), cronItem({ name: 'control' })]);
      expect(out.map((c) => c.name)).toEqual(['control']);
    });
  });

  describe('schedule', () => {
    it('is capped at 60 characters', () => {
      const out = cronOf([cronItem({ schedule: '*/5 '.repeat(30) })]);
      expect(out[0].schedule.length).toBeLessThanOrEqual(60);
      expect(out[0].schedule).toBe(('*/5 '.repeat(30)).trim().slice(0, 60).trim());
    });

    it('keeps an @special', () => {
      expect(cronOf([cronItem({ schedule: '@reboot', next_run: null })])[0].schedule).toBe('@reboot');
    });

    it('a schedule outside the cron character set (or not a string) drops the item', () => {
      const out = cronOf([
        cronItem({ schedule: '0 13 * * 1; rm -rf /' }),
        cronItem({ schedule: '<b>' }),
        cronItem({ schedule: 9 }),
        cronItem({ name: 'control' }),
      ]);
      expect(out.map((c) => c.name)).toEqual(['control']);
    });
  });

  describe('schedule_human', () => {
    it('is capped at 80 characters', () => {
      const out = cronOf([cronItem({ schedule_human: 'Daily at 08:00 '.repeat(20) })]);
      expect(out[0].schedule_human.length).toBeLessThanOrEqual(80);
      expect(out[0].schedule_human.startsWith('Daily at 08:00 Daily')).toBe(true);
    });

    it('markup or a non-string becomes "" (the item is kept)', () => {
      expect(cronOf([cronItem({ schedule_human: '<img src=x onerror=alert(1)>' })])[0].schedule_human).toBe('');
      expect(cronOf([cronItem({ schedule_human: 7 })])[0].schedule_human).toBe('');
      const missing = cronItem();
      delete missing.schedule_human;
      expect(cronOf([missing])[0].schedule_human).toBe('');
    });
  });

  describe('dates', () => {
    it('last_run and next_run must be ISO-8601 Z timestamps or become null', () => {
      const out = cronOf([
        cronItem({ last_run: 'yesterday', next_run: '2026-13-45T99:00:00Z' }),
        cronItem({ name: 'b', last_run: 12345, next_run: '' }),
        cronItem({ name: 'c', last_run: '2026-11-17 13:00:02', next_run: { a: 1 } }),
      ]);
      for (const item of out) {
        expect(item.last_run).toBeNull();
        expect(item.next_run).toBeNull();
      }
    });

    it('null stays null and a missing date becomes null', () => {
      const missing = cronItem();
      delete missing.last_run;
      expect(cronOf([cronItem({ last_run: null, next_run: null }), missing]).every((c) => c.last_run === null && (c.next_run === null || c.next_run))).toBe(true);
      expect(cronOf([missing])[0].last_run).toBeNull();
    });
  });

  describe('last_result', () => {
    it('keeps ok | failed | unknown', () => {
      const out = cronOf(['ok', 'failed', 'unknown'].map((r, i) => cronItem({ name: `j${i}`, last_result: r })));
      expect(out.map((c) => c.last_result)).toEqual(['ok', 'failed', 'unknown']);
    });

    it('anything else becomes unknown', () => {
      const out = cronOf([
        cronItem({ name: 'a', last_result: 'OK' }),
        cronItem({ name: 'b', last_result: 'success' }),
        cronItem({ name: 'c', last_result: 1 }),
        cronItem({ name: 'd', last_result: null }),
      ]);
      expect(out.map((c) => c.last_result)).toEqual(['unknown', 'unknown', 'unknown', 'unknown']);
    });
  });

  it('non-object entries are dropped without dropping the valid ones', () => {
    const out = cronOf(['x', null, 5, [], cronItem()]);
    expect(out).toEqual([cronItem()]);
  });
});
