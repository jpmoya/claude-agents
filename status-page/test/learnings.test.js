// src/learnings.js unit tests: markdown parsing, the KV record shape, and the merge/edit/delete
// functions that keep a re-push of the Mac's append-only file idempotent against page edits and
// deletes. Expected values are hand-derived from the one-way-sync design described in the PR,
// never copied from src/.

import { describe, it, expect } from "vitest";
import {
  parseLearningsMarkdown,
  loadLearningsRecord,
  mergePushedLines,
  editLearningEntry,
  deleteLearningEntry,
  MAX_ENTRY_TEXT_LENGTH,
} from "../src/learnings.js";

describe("parseLearningsMarkdown", () => {
  it("extracts bullet lines, stripping the leading dash and whitespace", () => {
    const text = ["- First lesson", "- Second lesson"].join("\n");
    expect(parseLearningsMarkdown(text)).toEqual([
      "First lesson",
      "Second lesson",
    ]);
  });

  it("ignores headings, blank lines and other prose, keeping only bullets", () => {
    const text = [
      "- Lesson before the heading",
      "",
      "# Message triage learnings",
      "- Lesson after the heading",
      "some stray prose with no dash",
    ].join("\n");
    expect(parseLearningsMarkdown(text)).toEqual([
      "Lesson before the heading",
      "Lesson after the heading",
    ]);
  });

  it("trims surrounding whitespace and drops empty bullets", () => {
    const text = "  -   padded lesson   \n-\n-   ";
    expect(parseLearningsMarkdown(text)).toEqual(["padded lesson"]);
  });

  it("non-string input returns an empty array", () => {
    expect(parseLearningsMarkdown(null)).toEqual([]);
    expect(parseLearningsMarkdown(undefined)).toEqual([]);
  });
});

describe("loadLearningsRecord", () => {
  it("a missing value reads back as empty", () => {
    expect(loadLearningsRecord(null)).toEqual({ entries: [], seen: [] });
  });

  it("corrupt JSON reads back as empty, never throws", () => {
    expect(loadLearningsRecord("not json{")).toEqual({ entries: [], seen: [] });
  });

  it("drops malformed entries and non-string seen values", () => {
    const raw = JSON.stringify({
      entries: [
        { id: "a", text: "ok", added_at: "2026-01-01T00:00:00Z" },
        { id: "bad" },
        "not-an-object",
      ],
      seen: ["ok", 5, null],
    });
    expect(loadLearningsRecord(raw)).toEqual({
      entries: [{ id: "a", text: "ok", added_at: "2026-01-01T00:00:00Z" }],
      seen: ["ok"],
    });
  });
});

describe("mergePushedLines", () => {
  it("adds new lines as entries with fresh ids", () => {
    const record = { entries: [], seen: [] };
    const merged = mergePushedLines(record, ["Lesson A", "Lesson B"]);
    expect(merged.entries).toHaveLength(2);
    expect(merged.entries.map((e) => e.text)).toEqual(["Lesson A", "Lesson B"]);
    expect(new Set(merged.entries.map((e) => e.id)).size).toBe(2);
    expect(merged.seen.sort()).toEqual(["Lesson A", "Lesson B"].sort());
  });

  it("pushing the same content twice produces no duplicates (idempotent push)", () => {
    const first = mergePushedLines({ entries: [], seen: [] }, ["Lesson A"]);
    const second = mergePushedLines(first, ["Lesson A"]);
    expect(second.entries).toHaveLength(1);
    expect(second.seen).toEqual(["Lesson A"]);
  });

  it("a push after the entry was deleted on the page does not resurrect it", () => {
    const pushed = mergePushedLines({ entries: [], seen: [] }, ["Lesson A"]);
    const afterDelete = deleteLearningEntry(pushed, pushed.entries[0].id);
    const rePushed = mergePushedLines(afterDelete, ["Lesson A", "Lesson B"]);
    expect(rePushed.entries.map((e) => e.text)).toEqual(["Lesson B"]);
  });

  it("a push after the entry was edited on the page does not add a duplicate", () => {
    const pushed = mergePushedLines({ entries: [], seen: [] }, ["Lesson A"]);
    const edited = editLearningEntry(
      pushed,
      pushed.entries[0].id,
      "Lesson A, revised",
    );
    const rePushed = mergePushedLines(edited, ["Lesson A"]);
    expect(rePushed.entries).toHaveLength(1);
    expect(rePushed.entries[0].text).toBe("Lesson A, revised");
  });

  it("a growing append-only file only adds the new tail lines", () => {
    const afterFirstPush = mergePushedLines({ entries: [], seen: [] }, [
      "Lesson A",
      "Lesson B",
    ]);
    const afterSecondPush = mergePushedLines(afterFirstPush, [
      "Lesson A",
      "Lesson B",
      "Lesson C",
    ]);
    expect(afterSecondPush.entries.map((e) => e.text)).toEqual([
      "Lesson A",
      "Lesson B",
      "Lesson C",
    ]);
  });

  it("caps stored text length at MAX_ENTRY_TEXT_LENGTH", () => {
    const long = "x".repeat(MAX_ENTRY_TEXT_LENGTH + 50);
    const merged = mergePushedLines({ entries: [], seen: [] }, [long]);
    expect(merged.entries[0].text).toHaveLength(MAX_ENTRY_TEXT_LENGTH);
  });
});

describe("editLearningEntry", () => {
  it("replaces the text of a matching entry, leaving seen untouched", () => {
    const record = {
      entries: [{ id: "a", text: "old", added_at: "2026-01-01T00:00:00Z" }],
      seen: ["old"],
    };
    const updated = editLearningEntry(record, "a", "  new text  ");
    expect(updated.entries).toEqual([
      { id: "a", text: "new text", added_at: "2026-01-01T00:00:00Z" },
    ]);
    expect(updated.seen).toEqual(["old"]);
  });

  it("returns null for an unknown id", () => {
    const record = { entries: [], seen: [] };
    expect(editLearningEntry(record, "missing", "text")).toBeNull();
  });

  it("returns null when the new text is blank after trimming", () => {
    const record = {
      entries: [{ id: "a", text: "old", added_at: "2026-01-01T00:00:00Z" }],
      seen: [],
    };
    expect(editLearningEntry(record, "a", "   ")).toBeNull();
  });
});

describe("deleteLearningEntry", () => {
  it("removes a matching entry, leaving seen untouched", () => {
    const record = {
      entries: [
        { id: "a", text: "keep", added_at: "2026-01-01T00:00:00Z" },
        { id: "b", text: "remove", added_at: "2026-01-01T00:00:00Z" },
      ],
      seen: ["keep", "remove"],
    };
    const updated = deleteLearningEntry(record, "b");
    expect(updated.entries).toEqual([
      { id: "a", text: "keep", added_at: "2026-01-01T00:00:00Z" },
    ]);
    expect(updated.seen).toEqual(["keep", "remove"]);
  });

  it("returns null for an unknown id", () => {
    const record = {
      entries: [{ id: "a", text: "keep", added_at: "2026-01-01T00:00:00Z" }],
      seen: [],
    };
    expect(deleteLearningEntry(record, "missing")).toBeNull();
  });
});
