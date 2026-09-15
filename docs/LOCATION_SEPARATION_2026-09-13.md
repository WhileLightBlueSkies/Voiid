# Location feature boundaries

Friends Map, direct-chat live location and group-chat live location must remain separate.

| Feature | Audience | Where updates appear | Stop behavior |
| --- | --- | --- | --- |
| Friends Map | Explicit Map audience | Friends Map | Map visibility controls only |
| 1:1 live location | Recipient of that conversation | That chat's bubble and location detail | That share only |
| Group live location | Authorized recipients in that group | That group's bubble and location detail | That share only |

## Fix

Both mobile Map tabs previously combined inbound conversation shares with Friends Map presence, giving the conversation fix precedence. This made a chat share appear on Friends Map even without a separate Map presence. Removed that combination on iOS and Android, including Android's chat-to-map conversion helper.

Chat banner bulk-stop actions now stop the displayed share IDs. A banner scoped to one conversation cannot stop unrelated chats. Friends Map retains its separate visibility lifecycle.

Existing server session scope is `(owner, kind, conversation)`; Map sessions must not carry a conversation ID. Chat sessions require active conversation membership for the sender and targets. Chat location detail filters participants by conversation ID. No server API or database migration changed in this fix.

## Device acceptance checks

1. With Friends Map off, share in a direct chat: only that chat should receive/display the location.
2. Share in a group at the same time: only that group's location detail should combine its participants.
3. Enable Friends Map for a separately selected audience: neither chat audience should change.
4. Stop one chat share: the other chat and Friends Map must continue.
5. Turn Friends Map off: both chat shares must continue until independently stopped or expired.
6. Repeat with an offline recipient, reconnect and expiry; stale/ended shares must not reappear as live.

These device checks still require execution with multiple accounts. Builds and coordinate-rejection tests do not substitute for that live validation.
