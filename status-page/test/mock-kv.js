// test/mock-kv.js — hand-written mock KV. Deliberately minimal: get(key) -> string|null and
// put(key, value), plus an operation counter for the "two get()s per render" / "one put() per
// accepted beat" assertions (design §2, §5). No bulk get([...]) — the design explicitly rejects
// it because its return shape can't be validated by a mock we wrote ourselves (#4 §1 rejected
// table), and the implementing host can't run wrangler to check a real one.

export function createMockKV(initial = {}) {
  const store = new Map(Object.entries(initial));
  const calls = { get: 0, put: 0, delete: 0 };

  return {
    async get(key) {
      calls.get++;
      return store.has(key) ? store.get(key) : null;
    },
    async put(key, value) {
      calls.put++;
      store.set(key, value);
    },
    async delete(key) {
      calls.delete++;
      store.delete(key);
    },
    // Test-only helpers — not part of the real KV API surface, never called by src/.
    _dump() {
      return Object.fromEntries(store.entries());
    },
    _calls() {
      return { ...calls };
    },
  };
}
