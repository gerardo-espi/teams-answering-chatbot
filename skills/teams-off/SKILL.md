---
name: teams-off
description: Turn off Teams auto-replies and stop this plugin's session schedules, preserving the whitelist.
---

# Turn replies off

Read `..\teams-auto-reply\SKILL.md` relative to this skill directory before acting.
Apply its safety rules and stop procedure in Start / stop / status.
Resolve this plugin's absolute root from this skill's location.

Run `Disable` before stopping schedules. List session schedules and stop only
those belonging to this exact plugin root. Do not stop unrelated schedules,
clear the whitelist, dismiss drafts, poll Teams, or send messages.

Verify `Status` and the schedule list. Report that replies are disabled and the
whitelist is preserved. No command can recall a send already in flight.
