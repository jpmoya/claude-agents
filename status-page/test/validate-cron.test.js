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

  describe('description (optional, plain text, capped at 140)', () => {
    it('is absent from items that do not send one (the stored item is unchanged)', () => {
      expect('description' in cronOf([cronItem()])[0]).toBe(false);
    });

    it('survives, em dash and a slash inside a word included', () => {
      const text = 'Daily layoff/closure recruiting scan — posts new finds to Slack';
      expect(cronOf([cronItem({ description: text })])[0].description).toBe(text);
    });

    it('collapses whitespace and control characters and trims', () => {
      expect(cronOf([cronItem({ description: '  Weekly \n\t scan\u0000  of  things ' })])[0].description).toBe('Weekly scan of things');
    });

    it('is capped at 140 code points', () => {
      const out = cronOf([cronItem({ description: 'ab '.repeat(100) })]);
      expect(Array.from(out[0].description)).toHaveLength(140);
      expect(out[0].description.startsWith('ab ab ab')).toBe(true);
    });

    it('a non-string or empty description leaves the key out (the item is kept)', () => {
      for (const description of [5, null, ['x'], { a: 1 }, '', '   ']) {
        const out = cronOf([cronItem({ description })]);
        expect(out).toEqual([cronItem()]);
      }
    });

    it('markup, an email, a URL, a path, an assignment or a long token drops the description and keeps the item', () => {
      const unsafe = [
        '<img src=x onerror=alert(1)>',
        'say "hi"',
        'back`tick`',
        'Tom & Jerry',
        'Mails someone@example.test daily',
        'Posts to https://hooks.example.test/T/B/X',
        'Reads ~/secrets nightly',
        'Reads /etc/passwd nightly',
        'Needs TOKEN=abc123 set',
        `Uses ${'a'.repeat(40)} as a key`,
        'Uses sk-abcdef123456 as a key',
        'Uses ghp_abcdef123456 as a key',
      ];
      for (const description of unsafe) {
        const out = cronOf([cronItem({ description })]);
        expect(out).toEqual([cronItem()]);
      }
    });
  });

  describe('source (optional enum)', () => {
    it('keeps cron | launchd | desktop', () => {
      const out = cronOf(['cron', 'launchd', 'desktop'].map((source, i) => cronItem({ name: `j${i}`, source })));
      expect(out.map((c) => c.source)).toEqual(['cron', 'launchd', 'desktop']);
    });

    it('anything else leaves the key out (the item is kept)', () => {
      for (const source of ['systemd', 'CRON', '', 7, null, ['cron']]) {
        expect(cronOf([cronItem({ source })])).toEqual([cronItem()]);
      }
    });

    it('a launchd-style schedule survives (@every, @keepalive, @app, a step range)', () => {
      const schedules = ['@every 900s', '@keepalive', '@app', '@calendar', '1-59/2 * * * *', '0 10-16/2 * * 4,5'];
      const out = cronOf(schedules.map((schedule, i) => cronItem({ name: `j${i}`, schedule, source: 'launchd' })));
      expect(out.map((c) => c.schedule)).toEqual(schedules);
    });
  });

  it('non-object entries are dropped without dropping the valid ones', () => {
    const out = cronOf(['x', null, 5, [], cronItem()]);
    expect(out).toEqual([cronItem()]);
  });
});
