---
name: create-memory
description: Use when about to create, save, or update a memory file in the persistent memory directory, including "remember this", "save a memory", or auto-memory writes at session end.
---

# Create Memory

Memory files are rule cards, not session logs. Every file matches this template exactly.

## Template

```markdown
---
name: <kebab-case-slug>
type: <user | feedback | project | reference>
---

- <Direct imperative: "Do X", "Never Y">
- <Next rule or step>
```

## Constraints

- Frontmatter has only `name` and `type`. No `description`, `originSessionId`, `metadata`, or timestamps.
- `name` is a kebab-case slug matching the filename, never a display title.
- Body under 100 words.
- Imperative bullets only. No headings, no paragraphs.
- Rule, fact, or step only. No dates, session stories, bug histories, "hit twice", or why-it-was-learned context.
- One fact per file. Update an existing file that covers the topic instead of adding a duplicate.
- After writing, add one line to `MEMORY.md`: `- [Title](file.md) — hook`.

## Example

```markdown
---
name: feedback-never-calculate-prices
type: feedback
---

- Read every Casa Verde price from the LCL DropShip Pricing sheet.
- Never compute, extrapolate, or reuse a cached price.
- If the sheet is unreachable, stop and say so.
```
