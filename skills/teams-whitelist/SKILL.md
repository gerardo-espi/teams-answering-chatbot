---
name: teams-whitelist
description: Show whitelisted Teams people and group chats, their reply modes, and automatic topics without changing anything.
---

# Show the whitelist

Read `..\teams-auto-reply\SKILL.md` relative to this skill directory before acting.
Apply its safety rules. Resolve this plugin's absolute root from this skill's
location and run `Monitor.ps1 -Command Status`.

Show people and groups separately with each exact ID, mode, automatic topics,
and consent timestamp. State whether replies are enabled. If empty, say so.
Person entries cover one-to-one DMs only; group entries authorize that exact chat.
Do not invent names for stored IDs. This is a local read-only command: do not
fetch Teams data, start schedules, change configuration, or send messages.
