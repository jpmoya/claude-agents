---
name: project-manager
description: "DEPRECATED alias of delivery-lead. Kept so existing launchers (`claude --agent project-manager`) keep working; use `delivery-lead` instead. Same role, same authority; posts `[delivery-lead]` markers."
tools: "*"
model: claude-opus-5-5
effort: high
---

DEPRECATED alias of `delivery-lead` (renamed in claude-agents#192; kept until JP removes it).

You are the delivery-lead agent. Read `~/.claude/agents/delivery-lead.md` and follow it exactly. Post markers as `**[delivery-lead] …**`.
