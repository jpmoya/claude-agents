// Direct unit test of the constant-time compare used for bearer-token auth (design §5: "pure-JS
// constant-time string compare (XOR-accumulate, no early return) — not
// crypto.subtle.timingSafeEqual, which doesn't exist in the Node test runtime").

import { describe, it, expect } from 'vitest';
import { constantTimeEqual } from '../src/index.js';

describe('constantTimeEqual', () => {
  it('returns true for identical strings', () => {
    expect(constantTimeEqual('same-token-value', 'same-token-value')).toBe(true);
  });

  it('returns false for different strings of the same length', () => {
    expect(constantTimeEqual('token-value-aaaa', 'token-value-bbbb')).toBe(false);
  });

  it('returns false for strings of different length', () => {
    expect(constantTimeEqual('short', 'a-much-longer-token-value')).toBe(false);
  });

  it('returns false comparing against an empty string', () => {
    expect(constantTimeEqual('non-empty', '')).toBe(false);
  });
});
