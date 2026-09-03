---
name: living
description: Update the project's living.md with a summary of what was done in the current session. Use when JP says "update living", "update living.md", or at the end of a significant work session. Works for any project — finds the living.md in the current repo root.
---

# Update Living Document

Append a new session entry to the project's `living.md`.

**living.md is written for Claude, not for humans.** Its only reader is a future agent loading it for context. Optimize for facts-per-token: same information, fewer words. Terse is correct here; polished prose is waste.

## How to find the file

1. Look for `living.md` in the current working directory's repo root (`git rev-parse --show-toplevel`, or the worktree's parent repo).
2. If it doesn't exist, create it with:
   ```markdown
   # Living Document — {project-name}

   Agent-readable session log. Newest first. Terse by design — see the `living` skill for format.

   ---
   ```

## Entry format

Insert at the top, after the `---` separator, before the first existing `## ` entry. Today's date.

```markdown
## YYYY-MM-DD — short-kebab-slug

SHIP: <thing that shipped, with PR #, IDs, figures>
DEC: <choice made> — <why>
FIND: <non-obvious fact / footgun / root cause>
OPEN: <unresolved item>
FILES:
- path/to/file — what changed
LESSON: <reusable insight, only if genuinely reusable>
```

One fact per line. Tags in that order; omit any tag with nothing to say. Repeat a tag as many times as needed. No section headers, no blank-line grouping beyond one blank line between tag groups.

## Rules

1. **This format always**, regardless of what the entries below it look like. Do not match the tone of older prose entries — the file is being migrated forward one entry at a time.
2. **No `**bold**`.** Ever. It is pure markup cost and adds nothing for an agent reader. Same for italics and blockquotes.
3. **Title is a kebab slug, not a sentence.** `west-elm-credit`, not "West Elm Credit: $6,505.24 Not $3,393.04, and Hidden Rows Made Scattered SKUs Look Contiguous". The entry body carries the content.
4. **Each fact appears exactly once**, under one tag. Do not restate a discovery under SHIP and again under LESSON.
5. **Compress prose, never compress identifiers.** Sheet IDs, draft/message/thread IDs, SKUs, dollar figures, PR numbers, file paths, env var names, commit SHAs, URLs — verbatim and complete, always. These are the irreplaceable part of the file; truncating one to save tokens destroys the entry's value. Drop adjectives, not digits.
6. **State the fact, not the discovery narrative.** "Remaining $ holds an overbilling on 1 of 46 rows; Remaining QTY=0 distinguishes it" — not "the surprising thing we found when we dug in was that…".
7. **Drop filler.** No "successfully", "we decided to", "it turns out that", "importantly", "note that". Articles and connectives can go where meaning survives.
8. **Tables only at 4+ columns.** A two-column `| File | What changed |` table is overhead — use `path — change` lines under `FILES:`. A 6-column SKU/model/price/stock grid is genuinely tabular; keep it.
9. **Include root cause and the "why"** — compression is about words, not content. A DEC line without its reason is worse than useless.
10. **LESSON is optional** and only for something reusable across sessions. No padding with the obvious.
11. **Reference PR numbers** whenever available.
12. **Edit the file in the main repo checkout**, not the worktree — living.md is project-level, not branch-specific. If only the worktree is available (repos with the `.worktrees/` edit hook), edit there and note it needs cherry-picking.

## Before / after

Before (prose, human-readable):
```markdown
## 2026-08-24 — West Elm Credit: $6,505.24 Not $3,393.04, the $494 Was Right and the Extended Total Was Wrong

**Discoveries:**
- **The $494 on SKU 4660081 was never the problem — the extended total was.** Order 00361152 quotes retail $494, 30% off, net $345.80, all correct. But two lines multiply **quantity by the pre-discount price**: 11 × $345.80 printed as **$5,434.00** (should be $3,803.80) and 10 × $345.80 as **$4,940.00** (should be $3,458.00). Audited all 46 lines: **44 are right, only these two are wrong.**
```

After (agent-readable):
```markdown
## 2026-08-24 — west-elm-credit

FIND: the $494 on 4660081 was correct; the extension was wrong. Order 00361152: retail $494, 30% off, net $345.80. Two lines multiply qty × pre-discount price: 11 × $345.80 printed $5,434.00 (s/b $3,803.80), 10 × $345.80 printed $4,940.00 (s/b $3,458.00). 44/46 lines right.
```

Every number and ID survived. `EXAMPLE.md` in this skill directory holds the full converted entry if you need a longer reference.

## Gathering context

- `git log --oneline -20` for recent commits
- Conversation history for PRs created/merged, bugs fixed, features shipped
- Architectural decisions and tradeoffs discussed
- Surprising discoveries and footguns

## After writing

Don't commit living.md — JP commits it manually or folds it into the next PR.
