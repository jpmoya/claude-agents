// src/learnings.js — the Learnings tab's data model: parsing the Mac-pushed plain-markdown
// bullet log, and the KV record shape (`learnings:entries`) that makes JP's browser edits/deletes
// stick without the Worker ever needing to write back to his Mac (it can't reach it).
//
// One-way sync, by design: the Mac's message-triage-learnings.md is append-only history and is
// the push source; the KV record is the separate, editable "what the page shows" list. A line's
// exact text is pushed at most once (tracked in `seen`, kept even after an edit or delete), so
// re-running the push script against the same (or a grown) file is always safe: already-seen
// lines are never re-added, so a delete or edit on the page is never undone by the next push.

export const MAX_LEARNINGS_PUSH_BYTES = 64 * 1024; // the Mac file is a few KB today; room to grow
export const MAX_ENTRY_TEXT_LENGTH = 1000;

/**
 * Pulls bullet lines out of a plain-markdown log: every line that starts with "-" once trimmed,
 * with the leading dash(es) and following whitespace stripped. Headings, blank lines and any
 * other prose are ignored — the file is free to carry a title or section headers alongside its
 * bullets (see ~/.claude/agents/message-triage-learnings.md on JP's Mac).
 * @param {string} text
 * @returns {string[]}
 */
export function parseLearningsMarkdown(text) {
  if (typeof text !== "string") return [];
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("-"))
    .map((line) => line.replace(/^-+\s*/, "").trim())
    .filter((line) => line.length > 0);
}

function isValidEntry(entry) {
  return (
    entry &&
    typeof entry.id === "string" &&
    typeof entry.text === "string" &&
    typeof entry.added_at === "string"
  );
}

/**
 * Parses the `learnings:entries` KV value. A missing/corrupt record (never pushed yet, or a
 * shape from a future version) reads back as empty rather than throwing.
 * @param {string|null} raw
 * @returns {{ entries: Array<{id: string, text: string, added_at: string}>, seen: string[] }}
 */
export function loadLearningsRecord(raw) {
  if (!raw) return { entries: [], seen: [] };
  try {
    const parsed = JSON.parse(raw);
    const entries = Array.isArray(parsed.entries)
      ? parsed.entries.filter(isValidEntry)
      : [];
    const seen = Array.isArray(parsed.seen)
      ? parsed.seen.filter((s) => typeof s === "string")
      : [];
    return { entries, seen };
  } catch {
    return { entries: [], seen: [] };
  }
}

/**
 * Adds any `lines` not already in `record.seen` as new entries; a line seen on a previous push
 * is skipped even if it was since edited or deleted on the page — that's what keeps re-pushing
 * the (append-only, ever-growing) Mac file idempotent.
 * @param {{ entries: Array<object>, seen: string[] }} record
 * @param {string[]} lines
 * @returns {{ entries: Array<object>, seen: string[] }}
 */
export function mergePushedLines(record, lines) {
  const seen = new Set(record.seen);
  const entries = record.entries.slice();
  const addedAt = new Date().toISOString();
  for (const line of lines) {
    if (seen.has(line)) continue;
    seen.add(line);
    entries.push({
      id: crypto.randomUUID(),
      text: line.slice(0, MAX_ENTRY_TEXT_LENGTH),
      added_at: addedAt,
    });
  }
  return { entries, seen: [...seen] };
}

/**
 * Replaces one entry's text in place. Returns null (caller renders 404) if `id` isn't found or
 * `text` is blank after trimming. `seen` is untouched — editing never re-opens the door for a
 * re-push of the entry's original line.
 * @returns {{ entries: Array<object>, seen: string[] } | null}
 */
export function editLearningEntry(record, id, text) {
  const idx = record.entries.findIndex((e) => e.id === id);
  if (idx === -1) return null;
  const trimmed = typeof text === "string" ? text.trim() : "";
  if (!trimmed) return null;
  const entries = record.entries.slice();
  entries[idx] = {
    ...entries[idx],
    text: trimmed.slice(0, MAX_ENTRY_TEXT_LENGTH),
  };
  return { entries, seen: record.seen };
}

/**
 * Removes one entry. Returns null (caller renders 404) if `id` isn't found. `seen` is untouched
 * on purpose — deleting is display-only; it must not let the next push of the Mac's append-only
 * file bring the line straight back.
 * @returns {{ entries: Array<object>, seen: string[] } | null}
 */
export function deleteLearningEntry(record, id) {
  const idx = record.entries.findIndex((e) => e.id === id);
  if (idx === -1) return null;
  const entries = record.entries.slice();
  entries.splice(idx, 1);
  return { entries, seen: record.seen };
}
