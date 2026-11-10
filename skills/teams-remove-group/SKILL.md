---
name: teams-remove-group
description: Remove an exact group chat from the Teams auto-reply whitelist without changing person entries.
---

# Remove a group chat

Read `..\teams-auto-reply\SKILL.md` relative to this skill directory before acting.
Apply its safety rules and Configure section only; do not poll or send messages.
Resolve this plugin's absolute root from this skill's location.

Run `Status` to inspect current group entries. Use the user's exact listed chat
ID, or resolve their supplied name through chat metadata and match the fetched
group ID against the whitelist. Follow the main skill's metadata pagination
restrictions; never fetch message bodies. Ask for missing or ambiguous input.
Never remove by a guessed ID or remove all groups when none was specified.

Run `Monitor.ps1 -Command RemoveGroup -TargetId` with the selected chat ID, then
verify with `Status`. If absent, report that it was not whitelisted. Person
permissions remain unchanged; removal cannot recall a send already in flight.
