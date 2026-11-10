# Teams answering Copilot plugin

Every **five minutes**, this plugin uses the running Copilot session's **existing
WorkIQ Teams connection** to check new messages and answer as you, only in
whitelisted destinations. No app registration, separate sign-in, client secret,
bot account, Node.js server, or Windows scheduled task is needed.

The responder starts disabled with an empty whitelist. Empty means **no Teams
reads or sends**.

## Install

Requires Windows, PowerShell 7.2 or newer (`pwsh`), GitHub Copilot CLI, and an
existing WorkIQ connection with Teams access in the current Copilot session.

```powershell
copilot plugin install gerardo-espi/teams-answering-chatbot
```

In Copilot, use `/skills reload` if the commands are not visible yet. Add the
people or groups you want, then run `/teams-answering-chatbot:teams-on`.

On another PC, install the plugin and configure its whitelist again. Local
configuration, consent timestamps, drafts, and delivery history are not published
or synchronized. Do not copy the encrypted ledger between Windows accounts.

## Use in this session

Use these dedicated slash commands (prefix each with
`/teams-answering-chatbot:`):

| Command | Arguments / effect |
| --- | --- |
| `teams-allow-person` | `<person> [auto or draft] [topics]` - add or update DM permission |
| `teams-allow-group` | `<group name or exact chat ID> [auto or draft] [topics]` - add or update that group |
| `teams-remove-person` | `<person or listed ID>` - remove DM permission only |
| `teams-remove-group` | `<group name or listed chat ID>` - remove group permission only |
| `teams-whitelist` | Show people, groups, exact IDs, modes, topics, and consent times |
| `teams-on` | Enable the current whitelist and start one five-minute session schedule |
| `teams-off` | Disable replies and stop this plugin's schedules; keep the whitelist |
| `teams-status` | Show enabled state, actual session schedules, counts, and limits |
| `teams-drafts` | List drafts; `approve <draft ID>` or `dismiss <draft ID>` explicitly |
| `teams-help` | Show commands and examples |

Examples:

```text
/teams-answering-chatbot:teams-allow-person Alex Example
/teams-answering-chatbot:teams-allow-group Weekend chat draft
/teams-answering-chatbot:teams-allow-person Alex Example auto greeting,thanks
/teams-answering-chatbot:teams-whitelist
/teams-answering-chatbot:teams-on
/teams-answering-chatbot:teams-off
/teams-answering-chatbot:teams-remove-group Weekend chat
```

Natural-language requests through `teams-auto-reply` still work. Adding a target
does not turn on the responder. `teams-on` applies to the entire current whitelist;
to stop replying to just one destination, remove its entry. Allow commands also
update existing entries' modes/topics without resetting their consent timestamp.
Automatic mode defaults to all supported casual topics unless narrowed explicitly.
Draft approval requires the exact original, destination, and reply to have been
shown and approved in this Copilot conversation; a bare draft listing never sends.

Copilot resolves names through your current connection and asks if ambiguous.
A person whitelist entry authorizes **only their direct chat**; group chats
require separate entries. A whitelisted group's human members can all trigger
replies in that group. Non-whitelisted messages are left untouched.

The skill is `skills\teams-auto-reply\SKILL.md`. Its start action creates one
five-minute recurring prompt in the current session; each prompt reads the skill
and performs one bounded poll. It does not create another Copilot process.
The session must remain running, connected, and the machine awake.
Start again in a new session; schedules are not an independent persistent service.

After adding commands to an already installed plugin, use `/skills reload` to
reload skills in the current session.

## Local development

```powershell
git clone https://github.com/gerardo-espi/teams-answering-chatbot.git
copilot --plugin-dir .\teams-answering-chatbot
```

Then ask to start the Teams auto-reply plugin. That session must already have your
WorkIQ connection available. Host tool approvals and organization policy still
apply; this plugin does not bypass either.

## Whitelist

`config.json` stores local policy and is ignored by Git, along with `.data`.
The helper creates it from `config.example.json` on first use without replacing
existing settings. Prefer the helper over hand editing so the consent timestamp
is recorded correctly:

```powershell
.\Monitor.ps1 -Command AllowPerson -TargetId 'PERSON-ENTRA-OBJECT-ID' -Mode auto
.\Monitor.ps1 -Command AllowGroup -TargetId 'EXACT-GRAPH-CHAT-ID' -Mode draft
.\Monitor.ps1 -Command AllowPerson -TargetId 'PERSON-ENTRA-OBJECT-ID' -Mode auto -AutoTopics greeting,thanks
.\Monitor.ps1 -Command RemovePerson -TargetId 'PERSON-ENTRA-OBJECT-ID'
.\Monitor.ps1 -Command RemoveGroup -TargetId 'EXACT-GRAPH-CHAT-ID'
.\Monitor.ps1 -Command Status
.\Monitor.ps1 -Command Drafts
```

Replace the illustrative IDs with real, resolved IDs. `auto` permits automatic
replies for `autoTopics`, saving other eligible topics as drafts. `draft` always
requires explicit approval in Copilot. Supported topics: `greeting`, `thanks`,
`farewell`, `wellbeing`, `weekend`, `hobbies`, `social`.

Only clearly casual conversation qualifies. Work/project, mixed, ambiguous,
system, bot, self, edited/deleted, attachment-bearing, and mentioned messages are
ignored. Meetings and channels are excluded. Replies are generated naturally by
this Copilot session, not restricted to canned phrases, but must not invent
personal facts, availability, activities, or commitments. Casual/work
classification is model judgment; routing is also checked by the local helper.
The whitelist is an application-level guard, not a restriction on the underlying
connection's OAuth permissions.

## Polling and delivery

`Monitor.ps1` has **no network or authentication code**. The skill uses WorkIQ
for reads/sends; the helper maintains a Windows-DPAPI-encrypted local ledger in
ignored `.data`. It checks account identity, whitelist, timestamps, duplicate
messages, approval mode, and cooldown, and persists a reservation before every
send. Pending drafts contain the source text and proposed reply, encrypted for
this Windows user.

Each poll looks up DMs with a server-side filter for each whitelisted person and
fetches whitelisted groups directly by their exact chat IDs. It does not scan the
full chat history. Discovery stops as soon as the exact DM's two members are
verified; unresolved destinations do not block resolved ones. Message bodies are
fetched only for chats authorized by the helper. All message pages must be fetched before
advancing a chat's checkpoint. Messages before recipient consent are not replayed.
Only the newest incoming message in a chat is considered; obsolete greetings
are not answered after the conversation moves on.

Default expiry is 30 minutes and cooldown is two minutes per chat. The latest
message and current whitelist are checked again before sending. Uncertain
deliveries and interrupted reservations are **never retried** automatically.
Records are pruned after 24 hours during active, nonempty-whitelist polling.
An account change blocks processing. If the connection expires, renew it through
its existing approved sign-in mechanism.

`Disable` prevents subsequent reservations but does not stop the recurring prompt;
ask the skill to stop to do both. No switch can recall a send already in flight.

## Offline checks

```powershell
.\tests\Plugin.Tests.ps1
```

These checks do not read Teams, authenticate, or send messages.
