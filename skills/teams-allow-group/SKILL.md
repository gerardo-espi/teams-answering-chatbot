---
name: teams-allow-group
description: Whitelist an exact Teams group chat for casual automatic replies or approval-only drafts.
---

# Allow a group chat

Read `..\teams-auto-reply\SKILL.md` relative to this skill directory before acting.
Apply its safety rules and Configure section only; do not start polling or send
messages. Resolve this plugin's absolute root from this skill's location.

Treat the user's arguments as a group name or exact chat ID and optional
mode/topics. If missing, ask for the group. Resolve through
`/me/chats?$select=id,topic,chatType&$top=50`, following metadata pagination under
the main skill's host restrictions. Only `chatType: group` qualifies; never
fetch message bodies to identify a group. For duplicate or unnamed groups, use
member metadata to disambiguate and ask the user to select an exact chat.
Verify supplied IDs through chat metadata too. Never guess an ID.

Run `Monitor.ps1 -Command AllowGroup` with the exact fetched chat ID. Default to
`-Mode auto` for the supported casual topics; honor explicit draft mode or
narrower topics. Explain that all human members can trigger replies in this group.
Verify with `Status`; do not enable the responder implicitly.
