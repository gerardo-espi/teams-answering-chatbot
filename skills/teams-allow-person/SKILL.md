---
name: teams-allow-person
description: Whitelist a person for casual Teams DM replies, or change their automatic topics or draft mode.
---

# Allow a person

Read `..\teams-auto-reply\SKILL.md` relative to this skill directory before acting.
Apply its safety rules and Configure section only; do not start polling or send
messages. Resolve this plugin's absolute root from this skill's location.

Treat the user's arguments as the person to allow and optional mode/topics.
If the person is missing, ask for one. Resolve their exact Entra object ID through
WorkIQ user metadata; ask if ambiguous. Run `Monitor.ps1 -Command AllowPerson`
with that ID. Default to `-Mode auto` for the supported casual topics; honor an
explicit draft mode or narrower topics. Never infer group permission.

Verify with `Status`. Report the resolved person, DM-only scope, mode, and whether
the responder is enabled. Do not enable it implicitly.
