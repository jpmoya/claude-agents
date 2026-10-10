// Issue #172: the PostToolUse Write|Edit prettier hook must be POSIX sh (the VM runs dash).
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const settingsPath = join(dirname(fileURLToPath(import.meta.url)), '../../settings.json');
const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
const entry = settings.hooks.PostToolUse.find((e) => e.matcher === 'Write|Edit');
const command = entry.hooks[0].command;

const run = (shell, file) =>
  spawnSync(shell, ['-c', command], {
    input: JSON.stringify({ tool_input: { file_path: file } }),
    encoding: 'utf8',
    env: { ...process.env, PH_SHELL: shell },
  });

let root;
beforeAll(() => {
  root = mkdtempSync(join(tmpdir(), 'prettier-hook-'));
  mkdirSync(join(root, 'node_modules/.bin'), { recursive: true });
  mkdirSync(join(root, 'src'));
  // stub prettier: records the file it was asked to write
  writeFileSync(
    join(root, 'node_modules/.bin/prettier'),
    `#!/bin/sh\necho "$2" > "${root}/ran-$PH_SHELL-$(basename "$2")"\n`,
    { mode: 0o755 },
  );
});
afterAll(() => rmSync(root, { recursive: true, force: true }));

describe('prettier PostToolUse hook', () => {
  it('has no bashisms: dash -n and bash -n both accept it', () => {
    expect(command).not.toContain('[[');
    for (const sh of ['dash', 'bash']) {
      expect(spawnSync(sh, ['-n', '-c', command]).status).toBe(0);
    }
  });

  for (const sh of ['dash', 'bash']) {
    for (const ext of ['js', 'jsx', 'ts', 'tsx', 'css', 'json']) {
      it(`${sh}: runs prettier on .${ext}`, () => {
        const f = join(root, 'src', `a.${ext}`);
        rmSync(join(root, `ran-${sh}-a.${ext}`), { force: true });
        const r = run(sh, f);
        expect(r.status).toBe(0);
        expect(existsSync(join(root, `ran-${sh}-a.${ext}`))).toBe(true);
      });
    }
    it(`${sh}: ignores other extensions and exits 0`, () => {
      const r = run(sh, join(root, 'src', 'notes.md'));
      expect(r.status).toBe(0);
      expect(existsSync(join(root, `ran-${sh}-notes.md`))).toBe(false);
    });
  }
});
