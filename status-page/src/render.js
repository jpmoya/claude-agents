// src/render.js — server-rendered HTML page. No JS emitted, no third-party resources.
//
// Mobile-first at 375px, prefers-color-scheme light/dark, inline <style>, <meta
// http-equiv="refresh" content="..."> driven by a page-refresh constant (AC15). Every value
// passes through esc() even though the payload is already enum-validated (defence in depth,
// tested directly per skills/quality-gate/SKILL.md).
//
// STUB — no branching, no string concatenation yet. Throws until implemented by the
// fullstack-developer.

// Auto-refresh interval in seconds. Must stay <= 30 (AC15). Grepped directly by tests.
export const PAGE_REFRESH_SECS = 20;

/** @param {unknown} value */
export function esc(value) {
  throw new Error('NotImplemented');
}

/**
 * @param {{ mac: object|null, vm: object|null }} hosts
 * @param {{ staleSecs: number, offlineSecs: number }} thresholds
 * @param {number} nowEpochSecs
 * @returns {string} full HTML document
 */
export function renderPage(hosts, thresholds, nowEpochSecs) {
  throw new Error('NotImplemented');
}
