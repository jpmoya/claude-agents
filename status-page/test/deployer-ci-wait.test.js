// Issue #158: deployer waits in-run for pending required checks; ci_pending only past the cap.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const agents = join(dirname(fileURLToPath(import.meta.url)), '../../agents');
const deployer = readFileSync(join(agents, 'deployer.md'), 'utf8');
const orch = readFileSync(join(agents, 'orchestrator.md'), 'utf8');

describe('deployer.md pending-check wait', () => {
  it('states a wait cap of at least 30 min', () => {
    expect(deployer).toMatch(/30 min/);
  });
  it('waits via repeated Bash calls under 10 min and says one call is capped at 10 minutes', () => {
    expect(deployer).toMatch(/single (Bash )?call is capped at 10 min/i);
    expect(deployer).toMatch(/each under 10 min/i);
  });
  it('merges or posts ci_red after waiting; ci_pending only for absent/queued past cap', () => {
    expect(deployer).toMatch(/wait[^.]*then merge[^.]*ci_red/i);
    expect(deployer).toMatch(/ci_pending[^.]*(past|beyond|after)[^.]*cap/i);
  });
  it('names a project-manager DECISION as the resume path, not relaunch/go', () => {
    const lines = deployer.split('\n').filter((l) => /ci_pending/.test(l));
    expect(lines.join('\n')).toMatch(/project-manager\] DECISION/);
    expect(lines.join('\n')).not.toMatch(/relaunch|\bgo\b/i);
  });
});

describe('orchestrator.md', () => {
  const caps = orch.split('\n').find((l) => l.startsWith('**Stage caps**'));
  it('deployer cap is 45 min; reviewers and infra-reviewer stay 10 min', () => {
    expect(caps).toMatch(/deployer\*{0,2} \*\*45 min\*\*/);
    expect(caps).toMatch(/reviewers, infra-reviewer \*\*10 min\*\*/);
  });
  it('has no ci_pending routing row; BLOCKED row names PM DECISION for ci_pending', () => {
    const rows = orch.split('\n').filter((l) => /ci_pending/.test(l));
    expect(rows.length).toBeGreaterThan(0);
    for (const r of rows) {
      expect(r).not.toMatch(/relaunch/i);
      expect(r).toMatch(/project-manager\] DECISION/);
    }
  });
});
