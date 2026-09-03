---
name: send-email
description: Use when about to send, reply to, or forward ANY email from any of JP's accounts (jp@benjis.com via gws CLI, jeanphilippe.moya@gmail.com, jp@casa-verde.ca, hello@benjisplants.com) — including "send it" on an existing draft, and including when a request only *implies* an email should go out (announce, follow up, share, notify, "update the thread"). The email-send-guard hook blocks all send commands that bypass this skill.
---

# Send Email

## Overview

Every outbound email needs JP's explicit approval of the exact final email, given through AskUserQuestion, immediately before sending. A PreToolUse hook (`~/.claude/hooks/email-send-guard.sh`) blocks all Gmail send commands unless a fresh approval marker exists. This skill is the only path to that marker.

**Implication is not approval. Ambiguity is not approval. Ask.**

## Workflow

1. **Route the account** per CLAUDE.md rules (benjis = gws CLI; personal / casa verde = googleapis via Bash; NEVER claude_ai MCP for personal matters, it is drafts-only anyway).
2. **Compose or locate** the email (new, draft, or reply — threading via `In-Reply-To`/`References` + `threadId`).
3. **Present the complete final email in chat**: From, To, Cc, Subject, full body verbatim, and every attachment/link. Not a summary — what JP approves must be byte-for-byte what sends.
4. **AskUserQuestion**: "Send this email?" with options `Send`, `Edit first`, `Save as draft only`. Header: "Send email?".
5. **Only if JP answers Send**: write the marker in its OWN Bash call, then send in a SEPARATE Bash call:
   ```bash
   # Call 1 — marker only (never combine with the send: the hook checks
   # for the marker BEFORE the command runs, so a combined command
   # self-blocks and the marker never gets written)
   date > ~/.claude/.email-send-approved
   # Call 2 — the send command (also keep the MIME-build step out of this
   # call: a hook denial kills the entire command, build included)
   <send command>
   ```
   One approval = one send. The marker is single-use (consumed by the next send-pattern command, pass or fail) and expires in 5 minutes.
6. **Report** the sent message ID and thread.

If JP answers anything else, or the content changes after approval, restart from step 3.

## What counts as approval

ONLY an explicit affirmative to *this exact email* after seeing it in step 3. A typed "send it" that unambiguously names this email also counts — but still show the final email first if it hasn't been shown this turn.

## Rationalizations — all mean STOP and ask

| Excuse | Reality |
|---|---|
| "The instruction implies sending" | The Jul 8 incident: "post in Slack saying we've already shared it" was read as send-approval. It wasn't. Implication ≠ approval. |
| "JP approved v1; this is just v2" | New content = new approval. |
| "He already saw the body earlier" | Show the final version again; approve what actually sends. |
| "It's urgent / EOD deadline" | AskUserQuestion takes 10 seconds. Un-sending takes forever. |
| "It's only a reply on an existing thread" | Same rule, every send. |
| "I'll just write the marker, the flow is obvious" | Marker without a fresh AskUserQuestion answer is a violation, not a shortcut. |

## Red flags

- About to run `date > ~/.claude/.email-send-approved` without an AskUserQuestion "Send" answer in this turn
- "Sounds good" about the *content* being treated as permission to *send*
- The hook denied a send and the reaction is to find another command shape

Drafts (`drafts create`) never need this skill — creating drafts is always safe.
