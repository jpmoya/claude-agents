---
name: quality-gate
description: Enforces unit tests and performance checks for every new feature, bug fix, or behavioral change — frontend and backend. Use when building, modifying, or extending any feature. Complements superpowers:test-driven-development with concrete backend/frontend testing patterns and mandatory performance gates.
---

# Quality Gate

Every new feature, bug fix, or behavioral change ships with **unit tests** and **performance checks**. No exceptions without explicit user approval.

This skill works alongside `superpowers:test-driven-development` — TDD governs the red-green-refactor cycle; this skill governs WHAT to test and WHERE to check performance.

## When This Skill Applies

- Adding a new feature (API endpoint, UI component, page, worker function)
- Fixing a bug
- Changing existing behavior
- Refactoring code that affects public interfaces

## The Gate

Before declaring any feature complete, ALL of these must pass:

```
Quality Gate Checklist:
- [ ] Unit tests written (test-first per TDD skill)
- [ ] Unit tests passing
- [ ] Edge cases covered (invalid input, empty state, auth failures, race conditions)
- [ ] Performance check completed (see Backend/Frontend sections below)
- [ ] No regressions in existing tests
```

If you cannot check all boxes, say so explicitly — don't silently skip.

---

## Backend Testing

### What to Test

| Layer | Must Test | Example |
|-------|-----------|---------|
| **API endpoints** | Every HTTP method, status code, and response shape | POST /api/register returns 200 with `{success: true}`, 400 for missing fields, 409 for duplicates |
| **Auth/session** | Token creation, validation, expiry, rejection of invalid/expired tokens | Session with pending user returns null |
| **Data access** | CRUD operations, key format, data integrity after writes | `createUser` stores lowercase email, `updateUser` merges without clobbering |
| **Validation** | Required fields, type coercion, length limits, format checks | Password min 8 chars, email required, tier must be `standard` or `preferred` |
| **Rate limiting** | Under-limit passes, at-limit blocks, key isolation | 5 requests from same IP pass, 6th returns 429, different IP unaffected |
| **Security boundaries** | Auth bypass attempts, privilege escalation, data leakage | Profile PUT ignores `status` and `email` fields; submissions endpoint filters `user:` keys |
| **Error paths** | Missing resources, malformed input, service failures | 404 for nonexistent user, 401 without auth header |

### Backend Test Structure

```javascript
// One describe block per endpoint or module
describe('POST /api/endpoint', () => {
  // Setup shared state
  let kv, env;
  beforeEach(() => {
    kv = createMockKV();
    env = { STORE: kv, ADMIN_KEY: 'test-key' };
  });

  // Happy path first
  it('creates resource with valid input', async () => { ... });

  // Then validation
  it('rejects missing required fields', async () => { ... });
  it('rejects invalid field values', async () => { ... });

  // Then auth/authz
  it('returns 401 without credentials', async () => { ... });
  it('returns 403 for unauthorized role', async () => { ... });

  // Then edge cases
  it('handles duplicate gracefully', async () => { ... });
  it('rate limits excessive requests', async () => { ... });
});
```

### Backend Mocking Rules

- **Mock infrastructure** (KV, D1, R2, external APIs) — these are I/O boundaries
- **Never mock business logic** — if validation, hashing, or data transforms are hard to test, the design needs fixing
- **Mock responses must match real shapes** — if KV returns `{keys: [{name: "..."}]}`, the mock must too
- **Test the real crypto** — don't mock `hashPassword`/`verifyPassword`; they're fast enough in tests and correctness matters

### Backend Performance Checks

Run after tests pass. These catch regressions before deploy.

**API response time** — endpoint handlers should complete in < 100ms with mock I/O:

```javascript
it('responds within 100ms', async () => {
  const start = performance.now();
  const ctx = createMockContext({ method: 'POST', body: validPayload, env });
  await handler(ctx);
  expect(performance.now() - start).toBeLessThan(100);
});
```

**Payload size** — API responses should be reasonably sized:

```javascript
it('response payload is under 10KB', async () => {
  const res = await handler(ctx);
  const body = await res.text();
  expect(body.length).toBeLessThan(10240);
});
```

**KV operation count** — catch N+1 queries or unnecessary reads:

```javascript
it('uses at most 3 KV operations', async () => {
  let ops = 0;
  const trackedKv = new Proxy(kv, {
    get(target, prop) {
      if (['get', 'put', 'delete', 'list'].includes(prop)) {
        return (...args) => { ops++; return target[prop](...args); };
      }
      return target[prop];
    }
  });
  env.SUBMISSIONS = trackedKv;
  await handler(createMockContext({ env, ...opts }));
  expect(ops).toBeLessThanOrEqual(3);
});
```

---

## Frontend Testing

### What to Test

| Layer | Must Test | Example |
|-------|-----------|---------|
| **Rendering** | Component mounts, shows correct initial state | Profile page shows user's company name and email |
| **User interactions** | Click handlers, form submissions, toggle states | "Edit Profile" button reveals inline edit form |
| **Form validation** | Client-side validation messages, submit prevention | Password confirm mismatch shows error before submit |
| **State transitions** | Loading → loaded → error, enabled → disabled | Submit button disabled during fetch, re-enabled on error |
| **Auth gating** | Redirect to login when unauthenticated, show content when authenticated | Profile page redirects to /login.html if no session |
| **Error display** | Network failures, API errors shown to user | "Account pending approval" message on 403 login |
| **Accessibility** | Keyboard navigation, ARIA attributes, focus management | Edit form focuses first input on open; Escape closes modal |
| **XSS prevention** | User-controlled text rendered safely | Company name with `<script>` tags escaped in innerHTML |

### Frontend Test Structure

For static HTML + vanilla JS (Cloudflare Pages style), test the JS functions directly:

```javascript
describe('esc() helper', () => {
  it('escapes HTML entities', () => {
    expect(esc('<script>alert("xss")</script>'))
      .toBe('&lt;script&gt;alert("xss")&lt;/script&gt;');
  });

  it('handles null/undefined', () => {
    expect(esc(null)).toBe('');
    expect(esc(undefined)).toBe('');
  });
});

describe('login form', () => {
  it('sends credentials to /api/login', async () => {
    // Mock fetch, simulate form submission, assert request
  });

  it('shows error message on 403', async () => {
    // Mock fetch returning 403, assert error div visible
  });

  it('redirects to pricing.html on success', async () => {
    // Mock fetch returning 200, assert location change
  });
});
```

For React/Vue/Svelte, use the framework's testing library (Testing Library, Vue Test Utils, etc.).

### Frontend Mocking Rules

- **Mock `fetch`** — never hit real APIs from unit tests
- **Mock `window.location`** — test navigation logic without actual redirects
- **Don't mock the DOM** — use jsdom (vitest default) or happy-dom; test real DOM behavior
- **Don't mock CSS** — if layout matters, test it with visual snapshots or computed styles

### Frontend Performance Checks

**Bundle / file size** — static assets should stay small:

```javascript
import { readFileSync, statSync } from 'fs';

describe('asset sizes', () => {
  it('HTML pages are under 100KB', () => {
    const pages = ['index.html', 'pricing.html', 'order.html', 'login.html', 'register.html', 'profile.html'];
    for (const page of pages) {
      const size = statSync(page).size;
      expect(size, `${page} is ${(size/1024).toFixed(1)}KB`).toBeLessThan(102400);
    }
  });

  it('no inline scripts exceed 15KB', () => {
    const html = readFileSync('page.html', 'utf-8');
    const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
    for (const body of scripts) {
      expect(body.length, 'Inline script too large — extract to file').toBeLessThan(15360);
    }
  });
});
```

**DOM complexity** — catch div soup and excessive nesting:

```javascript
it('page has fewer than 500 DOM elements', () => {
  document.body.innerHTML = pageHtml;
  expect(document.querySelectorAll('*').length).toBeLessThan(500);
});

it('no nesting deeper than 10 levels', () => {
  let maxDepth = 0;
  function walk(el, depth) {
    maxDepth = Math.max(maxDepth, depth);
    for (const child of el.children) walk(child, depth + 1);
  }
  walk(document.body, 0);
  expect(maxDepth).toBeLessThan(10);
});
```

**Render performance** — scripts should initialize fast:

```javascript
it('initialization completes in under 50ms', () => {
  const start = performance.now();
  initPage(); // the page's setup function
  expect(performance.now() - start).toBeLessThan(50);
});
```

---

## Test Runner Setup

If the project has no test runner yet, set one up before writing the first test.

**Default choice: Vitest** (works for both backend and frontend, ESM-native, fast).

```json
{
  "type": "module",
  "scripts": { "test": "vitest run" },
  "devDependencies": { "vitest": "^3" }
}
```

For projects with existing test runners (Jest, Mocha, Playwright), use what's already there.

### File Conventions

```
tests/
  mock-kv.js          # shared mock infrastructure
  auth.test.js         # backend: auth module
  api.test.js          # backend: API endpoints
  submissions.test.js  # backend: specific endpoint
  login-ui.test.js     # frontend: login page
  profile-ui.test.js   # frontend: profile page
  perf.test.js         # performance checks (both)
```

---

## Minimum Coverage by Change Type

| Change | Required Tests |
|--------|---------------|
| New API endpoint | Happy path + validation + auth + 1 edge case + response time |
| New UI page | Render + 1 interaction + auth gate + XSS escape + file size |
| Bug fix | Regression test reproducing the bug (red first) + verify fix (green) |
| Refactor | Existing tests still pass + no new behavior = no new tests needed |
| New shared module | All exported functions tested + edge cases for each |
| Security fix | Exploit test (demonstrates the vulnerability is closed) |

---

## Reporting

After all tests pass, output a summary:

```
Quality Gate: PASS
  Tests:       53 passed, 0 failed
  Performance: all checks within thresholds
  Coverage:    all new code paths tested
```

Or if something fails:

```
Quality Gate: FAIL
  Tests:       51 passed, 2 failed
  Failures:
    - POST /api/register: rate limit test expects 429, got 200
    - profile.html: file size 62KB exceeds 50KB limit
  Action needed: [specific fix]
```

---

## Escape Hatch

If a test or performance check is genuinely impossible or inappropriate (e.g., testing a one-time migration script, performance-checking a dev-only tool), say so explicitly and get user approval before skipping. Never silently omit.
