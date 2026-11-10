---
name: teams-allow-group
description: Whitelist an exact Teams group chat after asking which chat policy to apply.
---

# Allow a group chat

Read `..\teams-auto-reply\SKILL.md` relative to this skill directory before acting.
Apply its safety rules and Configure section only; do not start polling or send
messages. Resolve this plugin's absolute root from this skill's location.

Treat the user's arguments as a group name or exact chat ID and optional
policy/mode/topics. If missing, ask for the group. Resolve through
`/me/chats?$select=id,topic,chatType&$top=50`, following metadata pagination under
the main skill's host restrictions. Only `chatType: group` qualifies; never
fetch message bodies to identify a group. For duplicate or unnamed groups, use
member metadata to disambiguate and ask the user to select an exact chat.
Verify supplied IDs through chat metadata too. Never guess an ID.

Before every add or update, use `ask_user` to select/confirm one of all eight
named policies in the shared skill, even if the arguments already name a policy.
Never default silently. On decline/cancel, make no changes.
Run `Monitor.ps1 -Command AllowGroup` with the exact fetched chat ID and confirmed
`-Policy`; honor compatible restrictions on mode/topics. Explain that all human
members can trigger eligible replies in this group and report the chosen policy.
Verify with `Status`; do not enable the responder implicitly.
