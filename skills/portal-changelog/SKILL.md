---
name: portal-changelog
description: Post a user-facing changelog to Slack for the quoting portal or ops portal (scheduler). Use when JP asks to announce changes, post an update, or share what shipped in either portal's Slack channel.
---

# Portal Changelog

Post a plain-language summary of recently shipped changes to the portal's Slack channel — a rolled-up list of user-facing changes under a single header showing the **latest deployed version only** (no per-change version numbers).

## Arguments

`/portal-changelog quoting` or `/portal-changelog ops`. If no portal is given, infer from the repo you've been working in this session; if ambiguous, ask.

## Channels and repos

| Portal | Slack channel | channel_id | Repo | Version scheme |
|---|---|---|---|---|
| Quoting portal (quotes.benjis.com) | #quoting_portal | `C0BFS1X1Z3N` | `~/dev/benjis-quoting-tool` | `1.0.<commit count>` — `git rev-list --count origin/main`. Matches the sidebar footer. |
| Ops portal / scheduler | #ops_portal | `C0AHAU7GAR4` | `~/dev/scheduler` | `version` field in `package.json` on main. |

Post with `mcp__plugin_slack_slack__slack_send_message` to the channel_id. Do NOT DM Kyle separately — the channel replaces the old DM updates. Members post bugs/questions in these channels too; only respond to those if JP asks.

## Steps

1. **Find where the last post left off.** Read the channel's recent history (`slack_read_channel`) and find the latest changelog post and the version in its header. Only announce changes shipped after it. If the channel has no prior changelog post, cover roughly the current day's work — don't dump months of history.
2. **Gather the changes.** In the repo, `git fetch`, then `git log origin/main --oneline` (squash merges show as regular commits with PR-suffixed subjects like `(#58)`). Determine the current deployed version per the table above and confirm it is actually live before posting.
3. **Filter to user-facing.** Skip: tests, CI, deploy scripts, refactors, type fixes, anything a portal user can't see or feel. Include: new features, UI changes, pricing/calculation changes, bug fixes users would have noticed. Direct database corrections (done via SQL, no version) can be included when users would notice the data change.
4. **Write the post.** Format:
   - Header line: `` :mega: *<Portal name> update — now on `vX.Y.Z`* `` — the latest deployed version only — plus a reminder to hard-refresh and where the version shows (quoting portal: sidebar footer).
   - One bullet per change, **no version numbers on bullets** — all changes roll up under the header version.
   - Order bullets by user impact: pricing/output changes first, then new features, then UI polish.
   - Plain language for non-technical readers: say what the user sees or what changed for them — never file names, PR numbers, or jargon like "metadata"/"refactor". Say "quotes will come out higher" not "default parameter changed".
   - If a pricing change alters quote outputs, say so explicitly — that's the thing users most need to know.
   - Close with: `Questions or anything that looks off — post here or ping JP.`
5. **Ops portal (scheduler) only: verify docs are updated.** Before posting,
   check whether the change was user-facing; if so, verify the same PR
   updated the matching `docs/user-guide/` page. If it didn't, flag it to JP
   instead of silently posting the changelog.
6. **Post it**, then reply to JP with the message link.

## Rules

- Never announce unshipped work — only changes deployed to production.
- Several trivial changes can share a bullet; keep each bullet to one sentence. If it needs two, it's two changes.
- These are internal team channels, so posting doesn't need per-post approval once JP invokes this skill — but never post to any other channel or DM from this skill.
- Note: an unused duplicate #quoting-portal (`C0BFNDQJ78A`) exists from 2026-07-07 — never post there; the real channel is #quoting_portal (`C0BFS1X1Z3N`).
