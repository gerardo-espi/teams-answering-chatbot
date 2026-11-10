---
name: teams-remove-person
description: Remove a person from the Teams DM auto-reply whitelist without changing group entries.
---

# Remove a person

Read `..\teams-auto-reply\SKILL.md` relative to this skill directory before acting.
Apply its safety rules and Configure section only; do not poll or send messages.
Resolve this plugin's absolute root from this skill's location.

Run `Status` to inspect current people entries. Use the user's exact listed ID,
or resolve their supplied name through WorkIQ user metadata and match the fetched
ID against the whitelist. Ask for missing or ambiguous input. Never remove by a
guessed ID or remove everyone when no person was specified.

Run `Monitor.ps1 -Command RemovePerson -TargetId` with the selected ID, then verify
with `Status`. If absent, report that it was not whitelisted. Group permissions
remain unchanged; removal cannot recall a send already in flight.
