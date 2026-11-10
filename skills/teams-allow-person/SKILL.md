---
name: teams-allow-person
description: Whitelist a person for Teams DM replies after asking which chat policy to apply.
---

# Allow a person

Read `..\teams-auto-reply\SKILL.md` relative to this skill directory before acting.
Apply its safety rules and Configure section only; do not start polling or send
messages. Resolve this plugin's absolute root from this skill's location.

Treat the user's arguments as the person to allow and optional policy/mode/topics.
If the person is missing, ask for one. Resolve their exact Entra object ID through
WorkIQ user metadata; ask if ambiguous. Before every add or update, use `ask_user`
to select/confirm one of all eight named policies in the shared skill, even if
the arguments already name a policy. Never default silently. On decline/cancel,
make no changes. Run `Monitor.ps1 -Command AllowPerson` with the exact ID and
confirmed `-Policy`. Honor compatible restrictions on mode/topics.
Never infer group permission or change other existing entries.

Verify with `Status`. Report the resolved person, DM-only scope, policy, mode, and whether
the responder is enabled. Do not enable it implicitly.
