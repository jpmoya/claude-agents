// #837: a host that cannot run agents (Claude logged out, weekly / monthly spend limit) or is offline gets a large solid-red
// banner above every other alert: host, since when, duration, reason and one action. Expected values are hand-written from the ticket.

import { describe, it, expect } from 'vitest';
import { deriveAlerts } from '../src/alerts.js';
import { validateBeatPayload } from '../src/validate.js';
import { renderPage } from '../src/render.js';
import { validPayload, hostRecord } from './fixtures.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-11-27T14:25:00Z') / 1000; // 38 h 30 min after SINCE
const SINCE = '2026-11-25T23:55:00Z';
const ago = (mins) => new Date((NOW - mins * 60) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const down = (o = {}) => ({
  kind: 'agents_down',
  goal: 'some-vm-hostname',
  reason: 'Claude is logged out or its sign-in failed',
  hint: 'Log in on that host: claude auth login',
  since: SINCE,
  ...o,
});
const host = (o = {}) => {
  const { reportedMinsAgo = 1, ...rest } = o;
  return {
    ...hostRecord({ runs: [], received_at: ago(reportedMinsAgo) }),
    supervisor_last_tick: ago(reportedMinsAgo + 1),
    capacity: { running: 0, max: 3, queued: 0 },
    ...rest,
  };
};
const page = (mac, vm = null) => {
  const html = renderPage({ mac, vm }, thresholds, NOW);
  return html.slice(html.indexOf('</style>')); // markup only
};
const banner = (html) => {
  const m = html.match(/<section[^>]*data-testid="host-down-banner"[\s\S]*?<\/section>/);
  return m ? m[0] : '';
};
const alertList = (html) => {
  const m = html.match(/<section[^>]*data-testid="pipeline-alerts"[\s\S]*?<\/section>/);
  return m ? m[0] : '';
};
const entries = (html) => banner(html).match(/data-testid="host-down-entry"/g) || [];

describe('validate.js - agents_down', () => {
  const stalls = (entry) => validateBeatPayload(validPayload({ goal_stall: [entry] })).value.goal_stall;

  it('keeps the kind and its since timestamp', () => {
    expect(stalls(down())).toEqual([down()]);
  });
  it('drops a malformed since and keeps the entry', () => {
    for (const since of ['yesterday', '2026-11-25 23:55', '<b>2026-11-25T23:55:00Z</b>', 1764114900, null]) {
      const [e] = stalls(down({ since }));
      expect(e.kind).toBe('agents_down');
      expect(e).not.toHaveProperty('since');
    }
  });
  it('does not add since to the other kinds', () => {
    const [e] = stalls({ kind: 'token_scope', goal: 'vm', reason: 'project', hint: 'refresh', since: SINCE });
    expect(e).not.toHaveProperty('since');
  });
});

describe('render.js - host-down banner', () => {
  it('shows host, since, duration, reason and action in one red banner above every other alert', () => {
    const slow = { ...host(), supervisor_last_tick: ago(30) };
    const html = page(slow, host({ goal_stall: [down()] }));
    const b = banner(html);
    expect(b).toContain('VM cannot run agents');
    expect(b).not.toContain('some-vm-hostname'); // named Mac / VM, from the record it came in
    expect(b).toContain('Since Thu 26 Nov, 00:55'); // 23:55Z in Europe/Madrid (CET)
    expect(b).toContain('38 h 30 min');
    expect(b).toContain('Claude is logged out or its sign-in failed');
    expect(b).toContain('Log in on that host: claude auth login');
    expect(html.indexOf('data-testid="host-down-banner"')).toBeLessThan(html.indexOf('data-testid="pipeline-alerts"'));
    expect(alertList(html)).not.toContain('logged out');
    expect(alertList(html)).not.toContain('cannot be read');
    expect(alertList(html)).toContain('1 pipeline alert<');
  });

  it('is solid red and larger than the alert list', () => {
    const full = renderPage({ mac: host({ goal_stall: [down()] }), vm: null }, thresholds, NOW);
    const css = full.slice(0, full.indexOf('</style>'));
    expect(css).toMatch(/\.host-down \{[^}]*background: #b91c1c;[^}]*color: #ffffff;/);
    expect(css).toMatch(/\.host-down h2 \{[^}]*font-size: 1\.6rem;/);
  });

  it('never says all clear while a host is down', () => {
    const html = page(host({ goal_stall: [down()] }));
    expect(html).not.toContain('data-testid="alerts-clear"');
    expect(html).not.toContain('data-testid="pipeline-alerts"');
  });

  it('is absent on a healthy page', () => {
    const html = page(host(), host());
    expect(banner(html)).toBe('');
    expect(html).toContain('data-testid="alerts-clear"');
  });

  it('shows both hosts when both are down, each with its own action', () => {
    const limit = down({ reason: 'Claude weekly usage limit reached', hint: 'Wait for the reset or raise the limit' });
    const html = page(host({ goal_stall: [down()] }), host({ goal_stall: [limit] }));
    expect(entries(html)).toHaveLength(2);
    expect(banner(html)).toContain('Mac cannot run agents');
    expect(banner(html)).toContain('VM cannot run agents');
    expect(banner(html)).toContain('Wait for the reset or raise the limit');
  });

  it('still renders when since was dropped', () => {
    const { since, ...noSince } = down();
    expect(banner(page(host({ goal_stall: [noSince] })))).toContain('Since an unknown time');
  });

  it('escapes every value', () => {
    const html = page(host({ goal_stall: [down({ reason: '<script>x</script>', hint: '<img src=x>' })] }));
    expect(html).not.toContain('<script>x</script>');
    expect(html).not.toContain('<img src=x>');
  });
});

describe('render.js - offline and stale hosts', () => {
  it('puts an offline host in the same banner, since its last heartbeat, and not in the alert list', () => {
    const html = page(host(), host({ reportedMinsAgo: 90 }));
    const b = banner(html);
    expect(b).toContain('VM is offline');
    expect(b).toContain('Since Fri 27 Nov, 13:55'); // 90 min before 14:25Z, in CET
    expect(b).toContain('1 h 30 min');
    expect(b).toContain('Wake the host and check its supervisor is running');
    expect(entries(html)).toHaveLength(1);
    expect(alertList(html)).toBe('');
    expect(html).not.toContain('data-testid="alerts-clear"');
  });

  it('keeps a stale host amber in the alert list, out of the banner', () => {
    const html = page(host(), host({ reportedMinsAgo: 30, goal_stall: [down()] }));
    expect(banner(html)).toBe('');
    expect(alertList(html)).toContain('data-alert-id="host-stale-vm"');
    expect(alertList(html)).toContain('alert alert-amber');
  });

  it('shows only the offline entry for an auth alert last published by a host now offline', () => {
    const html = page(host(), host({ reportedMinsAgo: 90, goal_stall: [down()] }));
    expect(entries(html)).toHaveLength(1);
    expect(banner(html)).toContain('VM is offline');
    expect(html).not.toContain('logged out');
  });
});

describe('deriveAlerts - order', () => {
  it('lists the down hosts first, ahead of other red alerts', () => {
    const scope = { kind: 'token_scope', goal: 'mac', reason: 'project', hint: 'refresh' };
    const a = deriveAlerts({ mac: host({ goal_stall: [scope] }), vm: host({ goal_stall: [down()] }) }, thresholds, NOW);
    expect(a.map((x) => x.id)).toEqual(['agents-down-vm', 'gh-token-scope-mac']);
    expect(a[0].severity).toBe('red');
  });
});
