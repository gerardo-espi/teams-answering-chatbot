---
name: teams-on
description: Turn on Teams casual auto-replies and start one five-minute poll schedule for the current whitelist.
---

# Turn replies on

Read `..\teams-auto-reply\SKILL.md` relative to this skill directory before acting.
Apply its safety rules and explicit start procedure in Start / stop / status.
Resolve this plugin's absolute root from this skill's location.

Enable the responder and reuse or create exactly one five-minute session schedule
for this plugin root. The schedule must read the absolute main
`skills\teams-auto-reply\SKILL.md` and execute only Poll once, not this command.
Never add whitelist entries as part of starting. If the whitelist is empty, state
that nothing will be read or answered until the user explicitly adds a target.

Verify `Status` and the session schedule list. Report that this applies to the
current whitelist and requires this session to stay open; it is not a permanent
background service. Do not run an extra poll as part of this command.
