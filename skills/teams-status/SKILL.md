---
name: teams-status
description: Check whether Teams auto-replies are enabled and scheduled, plus whitelist counts and reply limits.
---

# Show responder status

Read `..\teams-auto-reply\SKILL.md` relative to this skill directory before acting.
Apply its safety rules and status procedure in Start / stop / status.
Resolve this plugin's absolute root from this skill's location.

Run `Monitor.ps1 -Command Status` and list session schedules. Report enabled or
disabled, whether a five-minute schedule exists for this exact plugin root,
person/group counts, maximum message age, and cooldown. Enabled configuration
alone does not mean polling is running; identify a missing schedule or duplicates
without changing them. Do not poll, send, fetch Teams data, or repair state.
