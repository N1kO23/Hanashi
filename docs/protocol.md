# Hanashi protocol (v3)

This document describes everything a client needs to talk to a Hanashi
server. The client-side Dart types live in `protocol/lib/src/`
(`encrypted_envelope.dart`, `envelope.dart`, `keys.dart`, `profile.dart` and
`api.dart`), and the client's encryption in `app/lib/e2ee/`. The Go server implements it in
`server/internal/`. `protocol/testdata/` holds fixtures that both
implementations are tested against.

All conversations are end-to-end encrypted with MLS (RFC 9420). The server
relays and stores ciphertext; it orders group changes but cannot read
messages or files, and it cannot add a reader to a conversation by itself
(see [Threat model](#threat-model)).

## Concepts

- **User IDs** look like `name@host`. `host` is the server's configured public
  host (`HANASHI_HOST`), not necessarily the address clients connect to. Names use
  1–32 characters from `a-z 0-9 . _ -`.
- **Devices.** Every sign-in creates a separate session with its own bearer
  token and device ID (a ULID). A user can be signed in on any number of
  devices at once. Each device has its own MLS keys.
- **Contacts.** Nobody can reach a user, or spend their key packages, without
  asking first and being accepted (see [Contacts](#contacts)). Being contacts
  and having a direct chat are separate: two contacts have one at most, which
  either of them starts.
- **Profiles and group state** have stores of their own (see
  [Profiles](#profiles) and [Group state](#group-state)), so that what a device
  knows about someone or a group does not depend on which messages it can read.
- **Envelope.** A chat message as written by the sending device: a small
  plaintext header plus ciphertext. The server validates the header and
  relays the rest as-is.
- **Event log.** Every change a device must mirror is an event with a global,
  strictly increasing `seq`. Devices keep the highest `seq` they have applied
  (their _cursor_) and catch up from it. Events from conversations a user is
  not in are skipped, so **gaps between seqs are normal** and must not be
  treated as missed events.
- **Conversation = MLS group.** The group ID is the conversation ID (a ULID
  chosen by the creating client). Every verified device of every member is
  one leaf of the group.
- **Media** is encrypted on the sending device and stored once per SHA-256 of
  its encrypted bytes (`sha256:<64 hex>`).

## Keys and verification

Every user has an **identity key** (Ed25519). It vouches for the user's
devices by signing each device's **record**:

```
hanashi-device-v1\n<userId>\n<deviceId>\n<mlsSigKey (base64)>
```

`mlsSigKey` is the device's MLS signature key, and the device's MLS
credential is the basic credential `<userId>/<deviceId>`. A device whose
record carries a valid identity signature is **verified**; only verified
devices take part in encrypted chats. Clients check signatures themselves
against identity keys they have pinned; the server's own check is only a
sanity check. `protocol/testdata/device_record.json` pins the exact bytes.

Clients pin a contact's identity key the first time they see it (trust on
first use). If the server later shows a different key:

- For a contact the user has not verified, the client pins the new key and
  adds a line to every chat with them saying that their security key changed.
- For a contact the user verified (see
  [Emoji verification](#emoji-verification)), the client trusts none of their
  devices, and messages to them wait, until the user verifies them again or
  accepts the new key. Accepting withdraws the verification on all of the
  user's devices.

The identity key and the key-backup secret live on each verified device and,
encrypted with the user's **recovery key**, in **secret storage** on the
server:

- Recovery key: 32 random bytes plus a 2-byte SHA-256 checksum, shown in
  Crockford base32 in groups of four characters.
- Secret storage blob: AES-256-GCM under
  `HKDF-SHA256(recoveryKey, info "hanashi-ssss-v1")`, with associated data
  the user ID.

A new device becomes verified in one of two ways. With the recovery key, it
opens secret storage, takes the identity key and signs its own record. Or the
user compares emoji between it and one of their verified devices, which then
hands it the identity key and the backup secret (see
[Emoji verification](#emoji-verification)).

| Method and path                    | Body                          | Response                                                                                                                                                             |
| ---------------------------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PUT /keys/identity`               | `{"identityKey", "reset"?}`   | `{"identityKey", "identityVersion"}`. A different key needs `"reset": true`, which voids all device signatures and secret storage (`409 identity_exists` otherwise). |
| `PUT /keys/device`                 | `{"mlsSigKey"}`               | `{}`. Registers the calling device's key; it cannot change (`409 device_key_exists`).                                                                                |
| `PUT /keys/devices/{id}/signature` | `{"signature"}`               | `{}`. Base64 Ed25519 signature over the device record, for one of the caller's devices.                                                                              |
| `GET /keys/users/{userId}`         |                               | `{"userId", "identityKey"?, "identityVersion"?, "devices": [{"deviceId", "mlsSigKey", "signature"?, "signedVersion"?}]}`                                             |
| `GET /keys/secret-storage`         |                               | `{"data", "identityVersion"}` or 404                                                                                                                                 |
| `PUT /keys/secret-storage`         | `{"data", "identityVersion"}` | `{}`. `data` is opaque (at most 16 KiB); the version must be current.                                                                                                |

Any change to a user's identity or device keys (including signing out or
revoking a device) emits a `device_keys_changed` event (`data: {"user"}`,
empty `conv`) to the user and to everyone sharing a conversation with them.

## MLS groups

Ciphersuite `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` (0x0001) only.
Application and handshake messages use the private (ciphertext) wire format.
GroupInfo carries the ratchet tree, so external joiners need nothing else.
Clients keep the secrets of the last 5 epochs, so messages sent just before a
commit still decrypt after it.

### Key packages

Each verified device keeps about 20 one-time key packages and one
last-resort package on the server, and tops them up on every connect. Before
adding users, a client claims one package per verified device of theirs.

| Method and path             | Body                                            | Response                                                                                                                                                               |
| --------------------------- | ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /keys/packages`       | `{"packages": [base64], "lastResort"?: base64}` | `{"count", "lastResort": bool}`. Verified devices only (`403 not_verified`); at most 100 one-time packages per device. A new last-resort package replaces the old one. |
| `GET /keys/packages/count`  |                                                 | `{"count", "lastResort": bool}`                                                                                                                                        |
| `POST /keys/packages/claim` | `{"devices": [deviceId]}`                       | `{"packages": {deviceId: base64}}`. Oldest one-time package first, then the last-resort one (which is not consumed). Devices with none are left out.                   |

### Commits and leases

Two devices must never commit to the same epoch: openmls merges a commit
locally as soon as it is created, so a rejected commit leaves a forked group.
The server therefore hands out a **commit lease** per conversation:

1. `POST /conversations/{id}/lease` with `{"epoch"?}` -> `{"leaseId", "epoch",
"expiresAt"}`, or `409 lease_held` while another device holds it (retry
   shortly). A device with a group sends the epoch it is at and gets
   `409 epoch_mismatch` instead of a lease if the conversation moved on: it
   catches up first, holding up nobody meanwhile. Leases last 30 seconds;
   asking again while holding one replaces it with a fresh one.
2. The client checks that its group is at `epoch` (it must have processed
   every commit event up to it), creates the commit, and submits it with
   `POST /conversations/{id}/commits` or the `commit` WebSocket frame:
   `{"leaseId", "epoch", "mls": base64 commit, "groupInfo": base64 GroupInfo
after the commit, "state"?: the group's state sealed for the new epoch (see
[Group state](#group-state)), "welcomes"?: [{"device", "data": base64 Welcome}]}`.
3. The server accepts it only with the valid lease and `epoch` equal to the
   conversation's, then appends an `mls_commit` event, advances the epoch,
   stores the GroupInfo and the state, releases the lease and delivers the
   Welcomes. The response is `{"seq"}`. Otherwise it answers `409 lease_invalid`
   or `409 epoch_mismatch`.

A device that does not commit after all (its group turned out to be behind,
or the commit failed) gives the lease back with
`DELETE /conversations/{id}/lease/{leaseId}`, so others need not wait for it
to expire. A device that finds the lease held does not wait for it while
events pile up: the holder's commit usually arrives and leaves nothing to
do, and otherwise it tries again a few seconds later.

If the server refuses a commit the client already merged, its group has
forked: it deletes the group and rejoins by external commit.

Any other trouble says nothing about whether the commit went through: no answer
at all, or a `5xx` from a proxy while the server restarts. The client makes no
other commit to that group until it knows, and goes by the event log, where the
first commit at an epoch is the one that counted:

- Its own commit at that epoch: it went through, and the group stays as it is.
- Another device's commit at that epoch: its own did not count, so it rebuilds.
- None, with `GET /conversations/{id}/group-info` still at that epoch, or with no
  commit on its way: it never went through, so it rebuilds.

A new conversation (a group, or a direct chat) is settled
by sending its request again, unchanged: the server answers a repeat with what the
first one made, without a second set of events or Welcomes, so the answer is the
same whether the first never arrived, arrived late, or went through. The client
does this at once, so that a lost answer is no failure to the user, and keeps the
request until it has an answer. A conversation the user was told did not work out
is then made as soon as the server can be reached. Asking for the same group again
(the same people and name) settles the one asked for before rather than making a
second; so does asking within a day of its being made that way. Only a refusal
(`403 not_a_contact`, say) makes the client drop the group it made.

Devices write down what a commit leaves to do before merging it, so all this also
holds for an app that closes at any point. If it comes back with the note but its
group is still at that epoch, the commit never happened, and the note is dropped.

Only devices verified with their user's current identity key may take a
lease, commit, create a conversation or send a message; others get
`403 not_verified`. A device left over from before a reset (on another
device) would otherwise rejoin every group, be removed again by the others,
and so on for as long as it runs. Clients check the same themselves: a
device that finds its own key replaced stays out of all groups and asks the
user to verify it again. (Users without an identity key are not checked;
the app always sets one up before any chat.)

`GET /conversations/{id}/group-info` -> `{"epoch", "data": base64}` returns the
latest GroupInfo, for external joins.

### Membership changes

- **Creating a group.** The client generates the ID, creates the group, claims
  key packages for every verified device of the other members and its own
  other devices, and commits the Adds locally. It then sends one request:
  `POST /conversations` with `{"id", "members", "mls": {"epoch", "groupInfo",
"state", "welcomes"}}`. Every other member must be the caller's contact
  (`403 not_a_contact`). A group can have just two people. The same request
  again gets the conversation it made; an ID someone else used is `409 id_taken`.
- **Direct chats** are built the same way, with `"direct": true` and the one
  other member, who must be a contact: `POST /conversations` with `{"id",
"members": [userId], "direct": true, "mls": {...}}`. Two people have one at
  most: if they have one already (the other one started it, or it is from when
  they were contacts before), the server answers with that, and the client
  discards its new group. Apps start it right after accepting a contact (see
  [Contacts](#contacts)), and when the user opens a chat with a contact who has
  none.
- **Adding a user** to a group is atomic with its commit:
  `POST /conversations/{id}/members` with `{"user", "commit": <commit body as
above>}`. They must be the caller's contact (`403 not_a_contact`). The
  `member_added` event precedes the `mls_commit` event, so members know the
  user belongs before they see the new leaves.
- **A member's new device** joins every conversation itself by external
  commit, using the stored GroupInfo, under a lease.
- **Leaving, signing out, revoking a device.** Remaining devices notice (from
  `member_removed` or `device_keys_changed`) and remove the stale leaves with
  a commit.

The server pushes Welcomes before the events that announce the conversation,
so a device can join from the Welcome rather than externally. A device that
finds a conversation without a local group checks its inbox for a Welcome
before falling back to an external join.

### Checking every group change

Because commits merge as soon as they are processed, clients validate the
group **after** each change and act on what they find:

- Every leaf must be `<userId>/<deviceId>` with the `mlsSigKey` of a verified
  record of that user, under the identity key the client pinned.
- A leaf added by external commit must belong to a user this device has
  already seen in the group; the server's member list is not enough, since
  the server could forge it. In a chat of two (as the group's leaves have it),
  the other one is enough if they are on the user's own contact list, as for a
  Welcome: otherwise a device that joined while they had no device there would
  keep them out for good.
- Leaves of users who are no longer members are removed routinely.
- A device removed again right after it joined by itself, three times in a row,
  waits before the next try: a minute, then twice as long each time, up to an
  hour. Until then it says so in the chat. Two devices that disagree would
  otherwise go round for as long as both run, with two commits a turn.

While a group holds a leaf the client does not accept, the client **refuses
to send** to it (messages wait in the outbox), shows why, and removes the
leaf with a commit. The exception is a changed identity key: that waits for
the user to accept it.

### Key rotation

A device updates its own leaf (self-update commit) after it has sent 100
messages with its current keys, or after 7 days, whichever comes first.
Creating or joining a group, and any removal it commits, count as an update.
This limits how long a stolen device key stays useful (post-compromise
security).

## Contacts

Who can reach whom. The server keeps how two people stand, so it can refuse
strangers; each user also keeps their own list, encrypted, which is what their
devices go by. Both are needed: the server's list keeps honest servers' users
from being pestered, and the user's own keeps a dishonest server from making
anyone a contact.

```
A asks                 POST /contacts/requests {"user": B}
                       B's devices get contact_changed {"user": A, "state": "incoming"}
B says yes             POST /contacts/requests/{A}/accept {}
                       both get contact_changed "accepted"
B's app starts         claims A's key packages, creates their direct MLS group,
their chat             POST /conversations {"id", "members": [A], "direct": true, "mls": {...}}
A joins                from the Welcome, as any member; both now share a group
```

A request says nothing but who asks: no text, no name. It cannot be encrypted,
as the two have no keys in common yet, and it consumes none of B's or A's
key packages. So a request shows only the user ID, which cannot be faked, unlike
a name one gives oneself.

Accepting and starting the chat are separate steps: being contacts does not
depend on having a chat, and two servers could not do both at once. The app of
whoever accepts starts the chat right after, because the two learn who the
other is through it (their profile keys) and verify each other over it. Apps
list a direct chat among the chats only once something is said in it. If the two
had one before (they were contacts once), the same one comes back, and the
client discards the group it made.

To the one asking, a request that was declined, or sent to someone who blocked
them, looks like one not answered yet, and asking again reaches nobody. Someone
blocked sees at most that a contact ended. The one declined can still be asked
by the one who declined.

| Method and path                          | Body       | Response                                                                                                                                                                                                                                                                                                                                                                                |
| ---------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /contacts`                          |            | `{"contacts": [{"user", "state", "since"}]}`, `state` one of `accepted`, `outgoing`, `incoming`, `blocked`                                                                                                                                                                                                                                                                              |
| `POST /contacts/requests`                | `{"user"}` | `{"state"}`: how the two stand now. `incoming`: they asked first, and the caller answers instead. Verified devices only. `404 user_not_found`, `404 other_server` (their ID names a server this one does not [federate](#federation) with), `502 server_unreachable` (their server cannot be reached), `409 blocked` (the caller blocked them), `429 too_many_requests` (50 unanswered) |
| `POST /contacts/requests/{user}/accept`  | `{}`       | `{"state": "accepted"}`, also again once they are contacts. `404 no_request` unless they asked and were not declined                                                                                                                                                                                                                                                                    |
| `POST /contacts/requests/{user}/decline` | `{}`       | `{}`                                                                                                                                                                                                                                                                                                                                                                                    |
| `DELETE /contacts/requests/{user}`       |            | `{}`: takes the caller's own request back                                                                                                                                                                                                                                                                                                                                               |
| `DELETE /contacts/{user}`                |            | `{}`: ends it for both. Their direct chat stays for what was said, but sending there answers `403 not_a_contact`                                                                                                                                                                                                                                                                        |
| `PUT /blocked/{user}`                    | `{}`       | `{}`: ends any relationship and keeps them from asking                                                                                                                                                                                                                                                                                                                                  |
| `DELETE /blocked/{user}`                 |            | `{}`                                                                                                                                                                                                                                                                                                                                                                                    |

`POST /keys/packages/claim` answers `403 not_a_contact` unless each device is the
caller's own, or belongs to a contact, or to someone with a request to the caller.

**The user's own list** is the account data blob `contacts` (see
[Account data](#account-data)): `{"contacts": {userId: {"addedAt", "key"?}}}`,
where `key` is their profile key, so a new device knows them at once. A device
adds someone before it asks or accepts. It takes a Welcome only if the
other one in a chat of two is on the list, or, for a group, if whoever the inbox
says sent it is, and someone on the list is in the group. Otherwise it does not
join, and the conversation does not show. A device joining by external commit
does the same check before it sends anything, passing also if another device of
the user is in the group. MLS does not say who wrote a Welcome, so in a group the
server could lie about that; but then one of the user's contacts is in that group.

If the list is gone because the account's keys were reset, a device that has seen
none under the new key fills it from the server's `accepted` and `outgoing`.

## Profiles

A user's name, picture and card are one signed record, one per user:

```
{"user", "version", "ct", "signature"}
ct        = AES-256-GCM(profile key, ProfileDocument JSON padded, aad "hanashi-profile-v1|<user>|<version>")
signature = Ed25519(identity key, "hanashi-profile-v1\n<user>\n<version>\n<base64 SHA-256(ct)>")
```

`ProfileDocument`: `{"displayName"?, "avatar"?: MediaRef, "card"?: MediaRef}`, the
name at most 64 characters. Later versions add fields; a device editing it keeps
those it does not know.

| Method and path           | Body                             | Response                                                                                                        |
| ------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `GET /users/{id}/profile` |                                  | The record, to the user and those sharing a conversation with them; otherwise, or without one, `404`            |
| `PUT /profile`            | `{"version", "ct", "signature"}` | `{"version"}`. `409 stale_version` unless newer than the one stored. `ct` at most 16 KiB. Verified devices only |

A change is one write; a `profile_changed` event (`{"user", "version"}`, nothing
more) tells the user's devices and those sharing a conversation with them, who
fetch it. A device takes a record only if the identity key it pinned for the user
signed it and it is no older than the newest it has seen, so the server can
neither forge one nor bring an old one back. A device that loses a race with
another of the user's (`stale_version`) reads the record again and applies its
change to that.

**The profile key** is 32 random bytes, in the account data blob `profile`:
`{"key", "previous"?, "rotate"?}`. Others get it as follows:

- a contact: with the group state of their direct chat, or the `profile_key`
  control message, and then on their own encrypted list;
- a group's members: in its [state](#group-state)'s roster.

A key from any of these is taken only if it opens the signed record of the one
it is said to belong to, so someone lying about another's key can cost that
profile at most, never forge one. (While someone has no record to try it on, the
key is kept for when they do; a right one replaces it.)

After each change to a group's state, a member whose key is missing from the
roster sends it in a `profile_key` control message (`{"key": base64}`), and the
next commit puts it in the roster. See [Control messages](#control-messages).

**When someone loses access** (no longer a contact, or no chat in common), the
device sets `rotate`. The next change gets a new key, so they cannot read anything
new; until then there is nothing new to protect. The new key goes to every
conversation in a control message, except direct chats with former contacts.
Meanwhile `previous` lets the user's other devices read the record the new key
has not replaced yet.

The **profile card** is what else the user tells about themself, as a JSON
file encrypted and uploaded like any attachment (`mime`
`application/json`), at most 16 KiB:

```json
{ "statusMessage": "Only the best for you!", "bio": "Teacher at Minato.\nLikes figures.", "birthday": { "month": 3, "day": 24 } }
```

| Field           | Meaning                                                                         |
| --------------- | ------------------------------------------------------------------------------- |
| `statusMessage` | A line shown under the name, at most 100 characters                             |
| `bio`           | What they tell about themself ("About me"), a few lines, at most 300 characters |
| `birthday`      | `{"month", "day"}`: a day of the year (February 29 included), never with a year |

Every field is optional. Devices fetch a card once per new `card` reference
and keep showing the previous one until they have it. A malformed field is
left out, not the whole card. Later versions add fields: devices keep the
ones they do not know and send them back unchanged when the user edits the
card, so an older version never erases them. Keeping the card in a file of
its own keeps the record small however much the card says.

A profile's picture is a square JPEG of 256 px, encrypted like any attachment.

## Group state

What a group is called and looks like, and its members' profile keys, reach a
device with the commits, without any of the group's messages. So someone just
added, or a brand-new device, knows them at once, and all members agree on them.

The state has two parts, sealed together:

```
GroupDocument: {"salt": base64 of 32 random bytes, new with each change, "title"?, "description"?, "picture"?: MediaRef, "emojis"?: {name: MediaRef}}
bundle:        {"doc": base64 of the document's exact bytes, "roster": {userId: base64 profile key}}
state:         base64(AES-256-GCM(secret, bundle JSON padded, aad "hanashi-state-v1|<conv>|<epoch>"))
secret:        the MLS exporter secret of <epoch>, label "hanashi-state-v1", context <conv>, 32 bytes
```

`title` is 1 to 64 characters; anything else makes the document malformed.
`description` says what the group is about, in a few lines, at most 500 characters;
a malformed one is left out. `emojis` are the group's custom emojis (see
[Custom emojis](#custom-emojis)), which any member changes as they would the
title; malformed ones are left out. Later versions add fields, which devices keep
and send back unchanged when they change the document.

Every member who is in an epoch can open what was sealed for it, and nobody else:
each commit moves the secret on, so someone removed cannot read what comes later.
There is no other key to rotate.

**Every commit says what it means for the document**, in its MLS authenticated
data: `version (1) | kind | SHA-256(document bytes)`, where `kind` is `0` (it stays
what it was), `1` (this commit changes it) or `2` (the committer does not hold it,
hash all zeros). MLS signs this data and includes it in the group's confirmed
transcript hash, so changing it gets the commit refused, and all who apply a commit
see the same. The GroupInfo, which the server keeps in the clear for external
joins, holds none of this; the salt keeps the server from testing guesses of a
title against the hash, which it can see in commits' authenticated data.

Why not a GroupContext extension: openmls 0.9.2 lets a group's extensions be
updated only with a `required_capabilities` extension listing them, and the Dart
bindings can make neither that nor an external join into a group with a custom
extension (`app/test/e2ee/mls_contract_test.dart`). GroupInfo is in the clear
anyway, so the document could not have gone there as such.

A device applying a commit from another:

- `1`: this hash is now pinned, and the document changes; a line in the chat says
  who changed what, going by the MLS sender and not by what the server says.
- `0`: for a device that verified what it holds, a different hash is ignored and
  logged: nobody can change the document without saying so. For a device that
  only believed whoever sealed it (below), the commit is right, and it now counts
  as verified.
- `2`: nothing.

A document is taken only if its hash is the pinned one. Otherwise what the device
has keeps showing, and the state counts as pending.

**Who changes it:** any member, by a commit under the lease, so changes come one
after another. A device behind gets `epoch_mismatch` or `StaleGroup`, catches up,
and applies its change to what is there now, so neither of two changes at once is
lost. This takes being online. There is no clock involved.

**Who sees it when:**

- Someone added: the state comes with the Welcome. They cannot check it against
  earlier commits, so they believe the member who sealed it until the next commit
  has its say.
- A device joining by itself cannot open what was sealed for the epoch before, and
  one rebuilding its group may have missed a change. So its commit says `2`, comes
  without `state`, and the server wakes the members (`Urgency: normal`). A rebuilding
  device goes on showing what it knew, but makes no claims about it and changes
  nothing until it hears. (With nobody else in the chat there is nobody to hear
  from, so it seals what it holds.) Any member holding the document then seals it
  after a short random wait: `PUT /conversations/{id}/state` with `{"epoch", "data"}`,
  answered `{}`, `409 state_exists` if another was quicker or `409 epoch_mismatch`.
  The others get a `group_state` event. Until then, a new device shows the group
  without a name, and neither it nor a rebuilding device can change the group's
  name or picture. A rogue member could seal something else first; the new device
  would believe it until the next commit, while those who hold the pinned hash
  ignore it.

`GET /conversations/{id}/group-info` answers `{"epoch", "data", "state"?}`. The
state is at most 128 KiB.

## Messages

### Envelope (what the server sees)

```json
{
  "v": 3,
  "id": "01JB2Y8Q3M7W2V6T0Q9X4C5D6E",
  "conv": "01JB2Y7Z0000000000000000AB",
  "from": "sota@chat.example.org",
  "device": "01JB2Y6A0000000000000000CD",
  "ts": 1729600000000,
  "type": "mls.app",
  "body": { "epoch": 7, "mls": "<base64>", "ct": "<base64>" }
}
```

| Field            | Meaning                                                                                 |
| ---------------- | --------------------------------------------------------------------------------------- |
| `v`              | Envelope version, `3`. Anything else is rejected.                                       |
| `id`             | ULID generated by the sending client. Retrying a send with the same `id` is idempotent. |
| `conv`           | Conversation ID.                                                                        |
| `from`, `device` | Sender's user and device; the server checks both against the session.                   |
| `ts`             | Sender's clock, milliseconds since the Unix epoch. Display only; ordering uses `seq`.   |
| `type`           | `mls.app`, or `mls.control` (see [Control messages](#control-messages)).                |
| `body.epoch`     | Group epoch the message was encrypted in.                                               |
| `body.mls`       | MLS application message (private message, authenticated data = the envelope `id`).      |
| `body.ct`        | The content, encrypted (below). The whole body is at most 64 KiB encoded.               |

Each message has its own random 256-bit **content key** K. The MLS
application message carries `{"k": base64 K, "h": base64 SHA-256(ct)}` as
JSON. `ct` is AES-256-GCM under K of the content JSON, [padded](#padding),
as random 96-bit nonce ‖ ciphertext ‖ tag, with associated data
`hanashi-msg-v2|<id>|<conv>|<from>|<device>`. Receivers check that the MLS
sender's leaf is the `from`/`device` of the header and that `h` matches
`ct`. Keeping the content outside MLS lets a device read old messages later
with K from the [key backup](#key-backup) or a [shared history](#sharing-history),
without the group's past secrets.

A device cannot decrypt its own MLS messages, so it keeps the content of what
it sent. Messages it cannot decrypt (sent before it joined) are kept and
shown as waiting for keys until the key backup or a shared history has their
key.

### Content (what members see)

`ct` decrypts to `{"type", "body"}`:

| `type`                   | `body`                                                                          |
| ------------------------ | ------------------------------------------------------------------------------- |
| `text`                   | `{"text": "...", "emojis"?, "replyTo"?: ReplyRef, "link"?: LinkPreview}`        |
| `image`, `video`, `file` | `{"media": MediaRef, "text"?: "caption", "emojis"?, "replyTo"?: ReplyRef}`      |
| `gif`                    | `{"media": MediaRef}` or `{"remote": RemoteMedia}`, with `"replyTo"?`           |
| `sticker`                | `{"media": MediaRef, "from"?}` or `{"pack", "id"}`, with `"replyTo"?`           |
| `call`                   | `{"call": callId}`: a voice call's place in the chat (see [Calls](#calls))      |
| `reaction`               | `{"target": messageId, "emoji": "👍", "remove"?: true}`                         |
| `edit`                   | `{"target": messageId, "text": "...", "emojis"?}`                               |
| `delete`                 | `{"target": messageId}`                                                         |
| `history`                | `{"user": userId, "keys": MediaRef}` (see [Sharing history](#sharing-history))  |
| `member`                 | `{"change": "created"\|"added"\|"left", "user"?: userId}` (below)               |

Unknown types must be kept and shown as unsupported, not dropped. Types a client
makes only for itself (`membership`, `encrypted`, `deleted`, `refused`) are never
taken from others: a message claiming one is shown as unsupported, so that
nobody can make a line saying the group was renamed, say, or that someone's key
changed.

**Lines about members.** Whoever changes the group's members says so, in a `member`
message to the group: its creator `created` once the server took it, a member who
added someone `added` with their `user` once the commit counted, and someone
leaving `left` just before they leave. It is encrypted and signed like any other
message, so it is that member's own word, and it is in the history, for those
added later with the history shared and for the user's new devices. It is only
ever about the sender's own change.

The server's `conversation_created`, `member_added` and `member_removed` events make
lines too, marked as the server's word (`"server": true`). Each `member` message
replaces the closest of these about the same change by the same person, with no
other change about that person in between, whichever came first. Those left over
(from someone whose device was gone before it said so) show as according to the
server.

`reaction`, `edit`, `delete` and `history` change something instead of showing in the timeline:

- **Reactions:** each adds an emoji to the sender's reactions to a message;
  a person can have several, but each emoji once. With `"remove": true` it
  takes that emoji back.
- **Edits:** new text for one of the sender's own messages, with the custom
  emojis it uses, which replace the message's. Edits by anyone else are
  ignored; the latest edit counts.
- **Deletions:** remove one of the sender's own messages for everyone.
  Devices replace it, the sender's edits of it and the text of replies
  quoting it with "This message was deleted", and drop its files. Before
  sending a deletion, the sender's device asks the server to drop the stored
  ciphertext of the message and of its edits (`POST /messages/delete`, see
  [REST API](#rest-api)), so devices that sync later never get them.
- **Shared history:** see [Sharing history](#sharing-history).
They can arrive before the message they are about (older history is fetched
later, keys come from the backup later), so devices keep them and apply them
whenever that message shows up. "Latest" means in server order, with
messages still in the outbox after all of them.

`ReplyRef`, the message a reply quotes: `{"id", "from", "text"?}`. `text` is
the quoted message's preview when the reply was written, at most 200
characters, for members who do not have the original. Devices that do have it
show its current text instead.

`MediaRef`:

```json
{
  "hash": "sha256:9f86d0...",
  "key": "<base64 32-byte file key>",
  "size": 512000,
  "mime": "image/jpeg",
  "name": "cat.jpg",
  "w": 1080,
  "h": 1440,
  "durationMs": 42000,
  "thumb": {
    "hash": "sha256:...",
    "key": "...",
    "size": 18000,
    "mime": "image/jpeg",
    "host": "example.org"
  },
  "host": "example.org"
}
```

`hash` is the SHA-256 of the **encrypted** file; `size`, `mime`, `name`, the
dimensions and the duration describe the plaintext and exist only inside the
encrypted content. `name`, `w`, `h`, `durationMs` and `thumb` are optional.
`host` is the host of the server the file was uploaded to: the uploading app
sets it to its own on everything it uploads. A reader on another server gets
the file through its own (see [Files across servers](#files-verification-typing-and-presence-across-servers)).
Without it, the file is on the reader's own server.
Thumbnails are at most 1280 px on the long side: JPEGs, or PNGs when any of
the picture is see-through. Audio goes as a
`file` with an `audio/*` type and, when the sending device could tell,
`durationMs`; apps play it.

A `gif` message shows a GIF playing: a file uploaded like any attachment
(`media`, e.g. one first sent as a photo and saved), or one that a provider
serves (`remote`). Sending a saved file again sends the same `MediaRef`;
nothing is uploaded. `RemoteMedia`:

```json
{
  "provider": "klipy",
  "id": "dancing-cat-1a2b",
  "url": "https://static.klipy.com/ii/.../md.webp",
  "mime": "image/webp",
  "w": 360,
  "h": 270,
  "title": "Dancing cat"
}
```

Every device loads it from the provider itself: KLIPY's terms do not allow
copies elsewhere, nor requests through a server. So a message cannot make a
device contact just anyone, `url` must be HTTPS on one of the provider's
hosts (for `klipy`: `klipy.com` and its subdomains), also after redirects.
Devices keep what they load in memory only. `title` is at most 100
characters.

GIF search (KLIPY's API, with the key from `GET /integrations`) also runs on
the device, without a user ID; KLIPY sees the device's IP address and what
it searches for. Apps let the user load GIFs in chats only on a tap instead.

A `sticker` message shows a picture by itself, without a bubble, 160 px square.
Its body is `{"media": MediaRef, "from"?}`, the picture itself, uploaded like
any attachment; one without `media` is malformed. One of the sender's own is an
image they made one (apps fit it into 512 px, never enlarging it, as a PNG if it
has transparency and a JPEG otherwise). One of a [sticker pack](#sticker-packs)
is the pack's picture as it is, and `from` says which pack: `{"pack": packId,
"id": stickerId, "title"?, "archive"?: MediaRef}`, `title` being the pack's as
the sender has it (at most 64 characters) and `archive` the pack's file, so that
whoever gets the sticker can add the pack. Apps show `media`, whatever packs
they have, and only offer the pack; a malformed `from`, or part of one, is left
out, never the message. Sending one sent or kept earlier sends the same
`MediaRef`: a device uploads a pack's sticker the first time it sends it.

Pack and sticker IDs are 1 to 64 characters of `A-Za-z0-9._-`.

Its preview, in the chat list and notifications, is `[Sticker]`.

### Sticker packs

A sticker pack is a zip file of `pack.json` and its stickers' pictures, all at
its top level:

```json
{
  "format": 1,
  "type": "sticker-pack",
  "id": "a-pack",
  "title": "A pack",
  "author": "Who made it",
  "cover": "01",
  "version": 1,
  "stickers": [{ "id": "01", "file": "01.webp", "emoji": "👋" }]
}
```

- `id` names the pack: the same ID is the same pack, whoever made the file. A
  new version of a pack keeps its ID and its stickers', which messages name.
  `author`, `cover` (the sticker that stands for the pack; the first if it
  names none), `version` and `emoji` are optional, and fields apps do not know
  are ignored. A `format` above what an app reads makes it say that it needs a
  newer version.
- 1 to 100 stickers, their IDs different apart from letter case; `title` and
  `author` 1 to 64 characters.
- Pictures are WebP, PNG (APNG too) or GIF, what their bytes are matching
  their file's name: `[A-Za-z0-9][A-Za-z0-9._-]{0,59}` and `.webp`, `.png` or
  `.gif`, in no folder. Each is at most 512 KiB and 1024×1024; an animated one
  512×512 and 150 frames.
- The file is at most 8 MiB, of at most 128 entries and 16 MiB unpacked as its
  zip's directory says, `pack.json` at most 64 KiB; entries are stored or
  deflated, never encrypted, never links, and none twice. Apps check this
  before inflating anything, inflate an entry no further than its size, read
  only what the manifest names, and never use an entry's name as a path.

A user adds a pack from a sticker someone sent (its `from.archive`), or from
its file. Either way their app checks it, uploads it again to their own server
with a key of its own (so it stays, whatever becomes of where it came from),
extracts it, and lists it in their account data (`packs`, see
[Account data](#account-data)); their other devices fetch it from there. A
sticker from a chat never replaces a pack of its ID the user has, and its pack
must have that ID; only a file replaces one, when the user says so. Removing a
pack keeps the stickers the user kept of it: those are pictures.

`app/tool/make_sticker_pack.py` makes a pack from a folder of pictures, and
checks one.

### Custom emojis

Text (a message's, a caption, an edit's) shows a picture wherever it says
`:name:` of one of the custom emojis that came with it, as `"emojis": {name:
MediaRef}`, the pictures uploaded like any attachment. So a message shows the same
to everyone, whatever becomes of the set its emojis came from.

- **Names** are 2 to 32 of `a-z`, `0-9` and `_`. Text shows one where `:name:`
  has one that came with it; two do not share a colon (`:a:b:` is `a`, then `b:`
  as text), and a name none came for stays text, without using up its colons.
  Apps leave out malformed entries, never the message, and show none in a link.
- **Pictures** are images of up to 128 px, made as stickers are (a PNG if they
  are see-through anywhere, a JPEG otherwise).
- **Sets:** the user's own, in their account data (`emojis`), and each group's,
  in its document. A message carries those of its text, at most 50: written in
  a group, the group's of a name before the user's own. An edit keeps the
  pictures of the emojis its message has.
- At most 100 in a set.

A group's members see a line when its emojis change: one added, removed,
renamed or given a new picture, with its name and picture, or that several
changed at once. Like the other lines, each device makes them for itself.

Web addresses in text and captions (`http://`, `https://`, or `www.`, which
means `https://www.`) open in the browser when tapped. A text message can
carry a preview of one of them, `LinkPreview`, made by the **sender's**
device before sending:

```json
{
  "url": "https://fxtwitter.com/someone/status/123",
  "kind": "video",
  "title": "Someone (@someone)",
  "description": "What they wrote",
  "site": "FxTwitter",
  "thumb": MediaRef,
  "media": MediaRef,
  "source": {"url": "https://video.example/v.mp4", "mime": "video/mp4", "w": 1280, "h": 720, "durationMs": 42000},
  "color": "#6363ff",
  "mime": "application/pdf",
  "size": 2400000
}
```

`kind` is `page`, `video` (a page showing a video), `gif` (a page showing a GIF,
or a silent video that plays like one), `image` or `file`. `mime` and `size` are
there only when the address is the file itself: what the site said, with `title`
its name. Unknown kinds show as pages. Everything but `url` is optional.
`thumb` is the page's picture or the image itself, uploaded and encrypted
like any attachment, made like a photo's thumbnail. `title` is at most 200
characters, `description` 300 and `site` 100. `color` is the page's
`theme-color`, as `#rrggbb`, for the bar beside the card; anything else is
ignored.

Receivers show a page's picture large below the text, as they do a video, except
one under 300 px on its long side (by `media`, else `thumb`), which is an icon:
small beside the text.

`media` is the video or GIF itself (`video/*` or `image/*`; anything else is
ignored), uploaded and encrypted like an attachment, so it plays in the chat:

- The sender's device takes it from the page's `og:video` (or
  `twitter:player:stream`) when that is a video file, not a player page, and
  from an animated GIF or WebP `og:image` when there is no video. When the
  address itself is a video or an animated image, the file itself is used.
- It is at most 25 MB and, in the app, a video the player can show. One without
  sound makes the preview a `gif`.
- For a `gif`, receivers play it in place, over and over, without sound (up to
  10 MB; larger ones on a tap). For a `video`, they play it in the viewer on a tap.
  Without `media`, a `video` card's picture opens the link.

`media` can also be a still picture: the image itself for an `image`, or a
`page`'s picture that is not an icon, as the site has it (JPEG, PNG, GIF or
WebP, up to 10 MB). Receivers show `thumb` in the chat and `media` in the
viewer; such a `media` has the `thumb` as its own `thumb`, to show until it is
there.

Sites that make embeds for chat apps (FxTwitter and the like) give their video
as `og:video`, so their links play in the chat; some give it only to the link
crawlers of chat apps they know, so the app's crawler says it is "like
TelegramBot", as Telegram's says it is "like TwitterBot".

`source` says where the site has the video or GIF: the address of the file
(HTTPS), its type (`video/*` or `image/*`) and, if known, its size and length.
The sender's device includes it whenever it found such a file, also one too
large to go along as `media`, which then makes the preview a `video`. Anything
else in it makes receivers ignore it, not the preview.

Receivers show the preview only while `url` is one of the addresses in the text
(an edit can remove it) and never contact the site for it: only the sender's
device does, once, while the message is being written. So neither the site nor
the server learns who reads the message. The one exception is the user's own
choice: an app may offer to load a video or GIF that did not come as `media`
from its `source`. The app keeps that off unless the user turns it on, and even
then fetches only in its media viewer, after asking each time and naming the
site. Videos stream through a server on the device itself that only the player
can reach, which fetches from the site under the same rules as previews (HTTPS,
public hosts, also after redirects); pictures and GIFs are downloaded first, up
to 100 MB. Like the rest of the message, a preview
is the sender's word: it need not match what the link leads to, and apps show
the address before opening it. Apps let the user turn previews off.

### Control messages

An envelope of type `mls.control` is built like any message, but belongs to no
chat: the server delivers it as a `control` event, in order, leaves it out of
history and snapshots, and wakes offline devices only with `Urgency: normal`. It
has no line in the timeline, counts as nothing unread, and its key goes in no
backup. A device that misses one loses nothing: what it says also reaches it some
other way. Today there is one kind, `{"type": "profile_key", "body": {"key": base64}}`
(see [Profiles](#profiles)); the sender is the MLS leaf, so nobody can send one for
someone else.

### Encrypted files

Each file and each thumbnail is encrypted with its own random key, in
64 KiB chunks so large videos never sit in memory whole:

```
"MTF2" ‖ 7-byte random nonce prefix ‖ chunk ‖ chunk ‖ ...
chunk = AES-256-GCM(key, nonce = prefix ‖ 32-bit big-endian counter ‖ last flag (0/1),
                    aad = the 11-byte header) = ciphertext ‖ 16-byte tag
plaintext = file ‖ 0x80 ‖ zero bytes, padded (below)
```

Receivers keep the plaintext up to the last byte that is not zero, which must
be the 0x80. Reordered, truncated or extended files fail to decrypt. Uploads use
`Content-Type: application/octet-stream`. Receivers verify the hash, then
decrypt into their local cache. A video downloads completely before it plays.

### Padding

So that the server sees only roughly how large something is, what is encrypted is
padded first:

- **JSON** (a message's content, a profile, a group's state, account data): spaces
  after it, which JSON allows, to 256 bytes at least, then to the next power of two
  up to 4 KiB, then to the next multiple of 4 KiB. A message's content is not
  padded past 47 KiB, so that it still fits in the envelope's 64 KiB body.
- **Files**: to the length [Padmé](https://petsymposium.org/popets/2019/popets-2019-0056.pdf)
  gives for the file plus the 0x80, at most 12% more, which leaves only about
  log log of the length to see. Never past what the server takes
  (`maxUploadBytes`): a file that would only fit with less padding gets less.

## Sync events

```json
{ "seq": 42, "type": "message", "conv": "01JB...", "ts": 1729600000123, "data": { ... } }
```

`ts` is the server's clock. Types and `data`:

| Type                   | `data`                                                             | Notes                                                                                                               |
| ---------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `message`              | an Envelope                                                        |                                                                                                                     |
| `control`              | an Envelope of type `mls.control`                                  | See [Control messages](#control-messages).                                                                          |
| `mls_commit`           | `{"epoch", "mls", "from", "device", "state"?}`                     | A commit for `epoch`; afterwards the group is at `epoch + 1`. Devices process them in order and skip their own.     |
| `group_state`          | `{"epoch", "data", "from", "device"}`                              | A member sealed the state for an epoch whose commit came without it.                                                |
| `conversation_created` | `{"conversation": ConversationInfo, "by": userId}`                 |                                                                                                                     |
| `member_added`         | `{"conversation": ConversationInfo, "user": userId, "by": userId}` | The added user receives it too.                                                                                     |
| `member_removed`       | `{"conversation": ConversationInfo, "user": userId}`               | The removed user receives their own copy and should delete the conversation locally.                                |
| `read_marker`          | `{"user": userId, "upTo": seq}`                                    | Delivered only to that user's devices; keeps unread badges in sync.                                                 |
| `device_keys_changed`  | `{"user": userId}`                                                 | `conv` is empty. Refetch the user's keys and check the groups you share.                                            |
| `profile_changed`      | `{"user": userId, "version"}`                                      | `conv` is empty. Fetch `GET /users/{user}/profile`.                                                                 |
| `contact_changed`      | `{"user": userId, "state"}`                                        | `conv` is empty. How the two stand now, as in `GET /contacts`, or `none`. Only to whoever it changes something for. |

`ConversationInfo`: `{"id", "isDirect", "members": [{"id"}]}`. Direct chats have
exactly two members, and there is at most one per pair. What a group is called,
only its members know (see [Group state](#group-state)).

Members can fetch a conversation's whole history, including messages from
before they joined, but can only read what they have keys for.

## Key backup

Every device puts the content key K of each message it sends or decrypts
into the account's **key backup** on the server, so the user's other
devices, including ones added later, can read the history. The server
cannot read or forge the entries: they are encrypted with the account's
backup secret, which only verified devices hold (see
[Keys and verification](#keys-and-verification)).

- Entry: AES-256-GCM under `HKDF-SHA256(backup secret, info
  "hanashi-backup-v1")`, as random nonce ‖ ciphertext ‖ tag, over the JSON
  `{"k", "h"}` that the MLS message carried, with associated data
  `hanashi-backup-v1|<message id>`, so an entry cannot be moved to another
  message.
- `POST /keys/backup` with `{"identityVersion", "entries": [{"id": message
  id, "data": base64 entry}]}` (1–500 entries of at most 512 bytes) answers
  `{"accepted"}`. The server keeps the first entry per message and ignores
  messages outside the user's conversations. `identityVersion` is the
  identity the device's backup secret belongs to: `409 identity_changed` if
  it is not the current one. A device uploads only while the server still
  shows its own identity key.
- `POST /keys/backup/query` with `{"ids": [message id]}` (at most 500)
  answers `{"entries": {id: data}}`; messages without an entry are left out.
- `GET /keys/backup?conv=<id>&after=<seq>` answers
  `{"entries": [{"id", "seq", "data"}], "more"}`: the caller's entries for
  that conversation's messages after `seq`, oldest first, 500 at a time
  (`404` for anyone not a member). For [sharing history](#sharing-history).
- When entries are added, the user's other connected devices get
  `{"type":"backup"}` and look again for keys of messages still waiting.
  Devices also look after every catch-up and after loading older history.
- Resetting the identity deletes the backup: the new backup secret cannot
  read it.

Devices upload in batches a few seconds after syncing or sending, and before
signing out. Messages that no device of the user ever read (for example,
sent in a group before the user was added) stay unreadable, unless someone
[shares the history](#sharing-history) with the user.

## Sharing history

Whoever adds someone to a group can give them the keys to the messages from
before (apps ask, with the box ticked). Right after the add, their device
sends a `history` message to the group, `{"user": <who was added>, "keys":
MediaRef}`. It puts the keys together when the message goes out: every
content key of the conversation that the account can read, from the device
and from the key backup (`GET /keys/backup?conv=`), as

```json
{ "keys": { "<message id>": { "k": "<base64 K>", "h": "<base64 SHA-256(ct)>" } } }
```

in a file encrypted and uploaded like any attachment, so only the group's
members get its key; the server learns only that a file was uploaded. If the
file would be larger than the server accepts, the oldest keys are left out;
without any keys, nothing is sent. Devices show "Kumiko shared the chat
history with Naoko" where the message is.

Only the devices of `user` take the keys, and they use each one only for a
message of the same conversation that comes before the `history` message (by
`seq`), and only if it opens that message (the hash and AES-GCM check out).
The key then goes into the user's own key backup like any other, so their
other devices, later ones included, read the same. A device that gets the
`history` message itself from the backup takes its keys too.

The added user cannot check the messages from before against MLS: they read
what the sharing member's account read, as that member's device says (see
[Threat model](#threat-model)). Messages after the share are read with MLS
only.

## Device inbox

Messages for one device (MLS Welcomes, type `mls.welcome`, and
[emoji verification](#emoji-verification) messages, `verification.*`) wait in
that device's inbox until it acknowledges them. They are pushed live as
`{"type":"inbox","item":InboxItem}` while the device is online.

`InboxItem`: `{"id", "type", "fromUser", "fromDevice", "createdAt", "data"}`.
For `mls.welcome`, `data` is `{"conv", "epoch", "data": base64 Welcome, "state"?}`.

| Method and path    | Body                                            | Response                                                                                                                                                                                                                                                                         |
| ------------------ | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /inbox`       |                                                 | `{"items": [InboxItem]}`, oldest first, at most 500                                                                                                                                                                                                                              |
| `POST /inbox/ack`  | `{"ids": [id]}`                                 | `{}`; removing an item twice is harmless                                                                                                                                                                                                                                         |
| `POST /inbox/send` | `{"to": [{"user", "device"?}], "type", "data"}` | `{"delivered": n}`. Only `verification.*` types, `data` a JSON object of at most 16 KiB, 1 to 10 recipients. Without `device`, every device of that user except the sender. Other users must share a conversation with the sender (`403 not_a_contact`); `404 device_not_found`. |

## Emoji verification

Two devices confirm each other's keys by comparing seven emoji, as in
Matrix's SAS verification. The request names one of two modes:

- `device`: a new, unverified device asks the user's other devices. The one
  that accepts vouches for the new device's `mlsSigKey`, and the new device
  learns that it holds the user's identity key. The verified device then
  sends the account secrets (identity key and backup secret) sealed for the
  new device, which signs its own record with them.
- `user`: a verified device asks a contact's devices. Each side vouches for
  its user's identity key.

The messages go through device inboxes (`POST /inbox/send`). Each carries
the transaction ID `txn`, a ULID the initiator picks:

| Type                   | Sent by                                                                       | `data`                                           |
| ---------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------ |
| `verification.request` | the initiator, to all of the other user's devices (in `device` mode, its own) | `{"txn", "mode": "device"\|"user"}`              |
| `verification.accept`  | the responder, once its user accepts                                          | `{"txn", "commitment"}`                          |
| `verification.key`     | both, the initiator first                                                     | `{"txn", "key"}`: an ephemeral X25519 public key |
| `verification.mac`     | both, once their user confirms the emoji                                      | `{"txn", "mac"}`                                 |
| `verification.secrets` | in `device` mode, the device that vouched                                     | `{"txn", "data"}`                                |
| `verification.cancel`  | either                                                                        | `{"txn", "reason", "acceptedBy"?}`               |

1. The responder makes an ephemeral X25519 key pair and accepts with
   `commitment = base64(SHA-256("HANASHI_SAS_V1|COMMIT|<txn>|<its key>"))`.
   Committing before it sees the initiator's key keeps either side from
   picking a key that makes a substituted exchange show the same emoji.
2. The initiator sends its key; the responder answers with its own, which
   the initiator checks against the commitment. The initiator also tells its
   request's other recipients that the request was taken (`cancel` with
   `acceptedBy`), so they drop it.
3. Both compute the X25519 shared secret `S` and derive keys as
   `HKDF-SHA256(S, info "<transcript>|<purpose>")`, without salt. The
   transcript is
   `HANASHI_SAS_V1|<initiator user>/<device>|<initiator key>|<responder user>/<device>|<responder key>|<txn>`.
4. Emoji: purpose `EMOJI`, 6 bytes. The first 42 bits, 6 at a time, index the
   64-emoji table Matrix uses (`app/lib/e2ee/sas.dart`).
5. Once its user confirms that the emoji match, each side sends
   `mac = HMAC-SHA256(key, keys)`. The key has purpose
   `MAC|<sender user>/<device>`. `keys` lists what the sender vouches for as
   sorted `<keyId>=<base64 key>` lines, joined with `\n`: `identity=...` for its
   user's identity key, or `device:<deviceId>=<mlsSigKey>` for a new device.
   Each side checks the other's MAC against the keys the server publishes for
   the other side; a mismatch cancels.
6. In `device` mode, `data` is
   `base64(nonce ‖ AES-256-GCM(key, secrets JSON, aad "HANASHI_SAS_V1|<txn>"))`,
   with a 32-byte key of purpose `SECRETS`.

Anyone in the middle (the server, say) who substitutes keys makes the two
devices show different emoji, and the users cancel. Devices ignore requests
older than 10 minutes, and a device that is not verified itself cannot
accept one.

### Trust statements

When a user verifies a contact, their device stores a signed **trust
statement** on the server, so that the user's other devices trust that key
too:

```
{"user", "identityKey": base64 or null, "at": milliseconds, "signature"}
```

The signature is the user's identity key's, over

```
hanashi-verified-v1\n<user>\n<identityKey, or empty>\n<at>
```

`"identityKey": null` withdraws the verification (the user accepted a new key
without verifying it). A device applies a statement only if the signature
checks out and `at` is later than that of the last statement it applied
about that contact. A new statement's `at` is later than the one it replaces,
even if the device's clock is behind. So the server can neither forge a
verification nor undo one by leaving out a statement or serving an older one.

| Method and path                   | Body                               | Response                                                                     |
| --------------------------------- | ---------------------------------- | ---------------------------------------------------------------------------- |
| `GET /keys/attestations`          |                                    | `{"attestations": {userId: data}}`: the caller's own statements              |
| `PUT /keys/attestations/{userId}` | `{"data"}` (opaque, at most 4 KiB) | `{}`. Replaces the caller's statement about that user; `404 user_not_found`. |

A `PUT` sends `{"type":"trust"}` to the user's other devices, which then
fetch the statements again; devices also fetch them every time they connect.
Resetting a user's identity deletes the statements their old key signed.

## Account data

Small blobs a user's devices share: their profile key (name `profile`, see
[Profiles](#profiles)), their contact list (`contacts`, see [Contacts](#contacts)),
their saved GIFs (`gifs`: `{"gifs": [GifRef, ...]}`, most recent first, each
`{"media": MediaRef}` or `{"remote": RemoteMedia}`; at most 100, fewer if they do
not fit), their stickers (`stickers`: `{"stickers": [StickerRef, ...]}`, most
recent first, each as in a `sticker` message, one of a pack as its picture with
`from`, or named `{"pack", "id"}` with nothing uploaded while the user does not
have its pack; at most 200, fewer if they do not fit), their sticker packs (`packs`:
`{"packs": [{"id", "title", "archive": MediaRef}, ...]}`,
most recent first, at most 100; see [Sticker packs](#sticker-packs)), their
custom emojis (`emojis`: `{"emojis": {name: MediaRef}}`, see
[Custom emojis](#custom-emojis)), and their settings for each chat (`chats`: `{"chats": {convId:
ChatSettings}}`, chats without any left out). Apps keep what they do not know
of `packs` and `stickers` (other keys, entries they cannot read, and the
fields of `packs` entries) and write it back unchanged.

A device changes a blob only from the version it read, and with a `version_conflict`
reads it again and applies its change to that, so two devices changing it at once
both keep their change. Inside the sealed blob is `{"n": count of changes, "data":
...}`. A device refuses an `n` below the highest it has seen under the account's
current key, and also having none at all after that, so the server cannot bring an
old blob back unnoticed: what the device has stays, and the next change, with a
higher `n`, puts things right. `n` counts on a device from the blob it read, or
from what it has seen, whichever is more.

`ChatSettings`: `{"notify"?, "mutedUntil"?, "sound"?}`, every field optional.
`notify` is what in the chat notifies: `all`, `replies` (replies and
reactions to the user only) or `off` (muted until the user unmutes it);
without it, the device's own settings decide. `mutedUntil` (milliseconds)
mutes the chat until then. `sound` is whether its notifications make a sound;
without it, the device's settings decide. Devices keep fields they do not
know and write them back unchanged. Names are 1 to 64 characters of `a-z`, `0-9`, `.`, `_`
and `-`. The server stores them without reading them: each is
`base64(nonce ‖ AES-256-GCM(key, JSON padded, aad "hanashi-account-data-v1|<userId>|<name>"))`
with `key = HKDF-SHA256(backupSecret, info "hanashi-account-data-v1")`, so
only the user's verified devices can open it. Resetting the identity (a new
backup secret) deletes them. Devices fetch what they need when they connect
and when told it changed.

| Method and path            | Body                                                                            | Response                                                                                                     |
| -------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `GET /account-data/{name}` |                                                                                 | `{"data", "version"}`, or `404 not_found`                                                                    |
| `PUT /account-data/{name}` | `{"data", "version"}` (opaque, at most 256 KiB; `version` as read, 0: none yet) | `{"version"}`, or `409 version_conflict`; sends `{"type":"account_data","name"}` to the user's other devices |

## Presence

Who of the people a user shares a conversation with is online. The server
works it out in memory and only ever sends it live; of all of it, it stores
only the mode each user chose, and never as events.

Each user has a status: `online`, `idle`, `focus` or `offline`. It follows
from the **mode** the user chose, which the server stores and which holds for
all of their devices, and from their devices' connections:

| Mode        | Status                                                                   |
| ----------- | ------------------------------------------------------------------------ |
| `auto`      | `online` while any of the user's devices is in use, `idle` while none is |
| `focus`     | `focus`. Only shown, for now: notifications are not silenced.            |
| `invisible` | `offline` to everyone else; the user still sees who is online            |

Without a connected device a user is `offline` in every mode. A device tells
whether it is in use with `{"type":"presence","state":"active"|"idle"}`; it
is in use until it says otherwise. Apps say `idle` after 5 minutes without
input (a pointer, a key, or the app coming to the front) and `active` again
on the next.

The server sends:

- right after `ready`, the status of everyone the user shares a conversation
  with, themself included, who is not `offline`, and the user's mode:
  `{"type":"presence","statuses":{userId: status},"mode"}`;
- whenever a user's status changes, `{"type":"presence","user","status"}` to
  the devices of everyone they share a conversation with, and the same with
  `"mode"` to their own devices (also when only the mode changed).

A device that starts sharing a conversation with someone (`conversation_created`,
`member_added`) asks for everyone's status again with `{"type":"presence"}`,
and gets the first kind of frame back. `PUT /presence` with `{"mode"}` sets the
mode. `GET /presence` answers `{"mode"}`, for a device that has no connection
to hear it on (one woken by a push): apps hold notifications while the user
is in focus, and show what waited, without a sound, once focus ends.

## Client levels

A server can refuse apps too old to work with it. Each app has a **client level**,
a whole number that says what it can do, and each server has a minimum,
`minClient` in `GET /server`. App versions are not used for this: development
builds do not carry a real one, and the level changes only when compatibility
does.

| Level | Apps                                                                                          |
| ----- | --------------------------------------------------------------------------------------------- |
| 5     | 0.9.0 on: the first level, and the lowest the server takes (apps before 0.9.0 cannot connect) |

- An app says its level on every HTTP request, in the header
  `X-Hanashi-Client: <level>`, and in its WebSocket `auth` frame as
  `"client": <level>`. Saying nothing counts as level 0.
- Below the minimum, every request except `GET /server` answers
  `426 client_too_old`, and a WebSocket gets `{"type":"error","error":"client_too_old"}`
  and closes with code 4002. This comes before anything else is looked at,
  including the token, so nothing the request asked for has happened.

**An app treats this differently from any other refusal.** Nothing is wrong with
what it asked for, so it signs nobody out, keeps its messages waiting in the
outbox, does not rebuild a group whose commit got this answer, and does not
retry until it has been updated. It still shows what it has locally.

**When levels change:**

- Raise `clientLevel` (`protocol/lib/src/api.dart`) in any app release that a
  later server might need to tell apart from those before it: when it starts
  doing something new that servers will come to rely on, or it fixes something a
  server should be able to insist on.
- Raise `MinClient` (`server/internal/protocol/protocol.go`) only when a server
  drops what older apps need, and only after apps of that level have been out for
  long enough to reach people. It can never be above the `clientLevel` of a
  released app, or nobody could connect.
- An operator can ask for more than their server needs with `HANASHI_MIN_CLIENT`, to
  retire a faulty app, say. It cannot go below `MinClient`.

## Keeping a device in sync

Connect, then catch up, in this order, every time the connection is
(re)established:

1. Open `GET /ws` and send `{"type":"auth","token":"<token>","client":<level>}`
   (see [Client levels](#client-levels)).
2. Wait for `{"type":"ready"}`. From now on, every new event is pushed as
   `{"type":"event","event":SyncEvent}`. **Buffer them.**
3. Process the inbox (`GET /inbox`): join groups from Welcomes, then
   acknowledge them.
4. Catch up over REST:
   - First run (no cursor): `GET /sync` returns a snapshot of all
     conversations with their latest 30 messages and read markers, plus a
     cursor.
   - Otherwise: `GET /sync?since=<cursor>` repeatedly until `more` is false,
     applying each page and storing its `cursor`.
5. Apply buffered events with `seq` greater than the cursor, then apply live
   events as they arrive.
6. Repair groups: join any conversation without a local group (external
   join), remove leaves the device does not accept, and top up key packages.

Events must be applied one at a time, in order: a message can only be
decrypted after the commits before it. Everything is idempotent: applying an
event twice must have no further effect. Messages are keyed by envelope `id`.

## Sending

Write the message to a local outbox first so it survives restarts, then:

1. For media, encrypt the thumbnail and original and upload them with
   `POST /media` (uploading the same bytes again is harmless).
2. Encrypt the message for the current epoch and send it over the WebSocket:
   `{"type":"send","rid":"<request id>","envelope":Envelope}`.
   The server answers `{"type":"ack","rid":...,"seq":n}` or
   `{"type":"nack","rid":...,"error":"<code>","status":<http status>,"message"?,"server"?}`.
3. The message also arrives as a `message` event on every device of every
   member, the sending device included (possibly before the ack). Match it to
   the outbox entry by envelope `id`.

Encrypt at send time, not when the message is queued: the group may have
moved on meanwhile. While the group is behind or holds an unaccepted leaf,
the message stays in the outbox.

The server accepts a message only for the conversation's current epoch
(`body.epoch`); otherwise it answers `409 epoch_mismatch`. A member added
since could never read such a message, and one removed since still could.
The device keeps the message pending, processes the commits it has not
applied yet (they are already on their way) and encrypts it again. If a
moment later its group is still at another epoch than the server's GroupInfo
and no commit for it is waiting in `/sync`, it missed one for good (or went
ahead of everyone): it rebuilds its group by external commit and sends then.

If the connection drops before the ack, keep the message pending and send it
again after reconnecting; the server answers a repeated `id` with the original
seq. On a `nack` with status 4xx other than 401/408/429 (and
`epoch_mismatch` and `not_verified`), mark it failed: retrying unchanged will
not help.

A conversation another server orders can be held up on its own: on
`502 server_unreachable`, `504 no_clear_answer` (see
[Conversations across servers](#conversations-across-servers)) and
`503 conv_moved` (see [Handing a conversation over](#handing-a-conversation-over)),
keep that conversation's messages pending, go on sending the other
conversations', and try again later (apps wait 15 s, doubling up to 5 minutes,
and at once after reconnecting). The `server` of a `server_unreachable` names the server that
could not be reached, for telling the user why their messages wait.

Read markers work the same way:
`{"type":"read","rid":...,"conv":"...","upTo":seq}` is answered with
`{"type":"ack","rid":...,"readUpTo":n}`.

`POST /messages` and `POST /conversations/{id}/read` do the same over HTTP,
for scripts and bots that do not keep a WebSocket open.

## Push notifications

Devices that are not connected are woken with [Web Push](https://www.rfc-editor.org/rfc/rfc8030):
the Android app registers with a UnifiedPush distributor (an app such as
ntfy, or Google's FCM built into the app) and gives the server the endpoint
it got. A push only tells the device to sync; it carries no conversation,
sender or content. The device then catches up over HTTP like any other
time, decrypts, and shows its own notification.

- The server has a P-256 **VAPID** key (RFC 8292), created on first start
  and kept in the database. `GET /server` returns its public key as
  `vapidKey` (base64url, uncompressed point); clients register their
  subscription for it. FCM requires it.
- `PUT /push/subscription` with `{"endpoint", "keys"?: {"p256dh", "auth"}}`
  (base64url, as in the Push API) sets the calling device's endpoint;
  `DELETE /push/subscription` removes it. Signing out removes it too.
- The payload is `{"type":"sync"}`, encrypted for the subscription's keys
  with the `aes128gcm` content coding (RFC 8291), or empty without keys.
- New messages push with `Urgency: high`, `Topic: message`, a TTL of one day,
  to every device of every other member that has no live WebSocket. Reading
  a conversation pushes the reader's other offline devices with
  `Urgency: normal` and `Topic: read`, so they can remove the notification.
  A contact request, or its acceptance, pushes the other one's devices like a
  new message, and apps notify it. A `control` message, and a commit that came without the group's
  state, push with `Urgency: normal` and `Topic: state`: others wait for a device
  to act on them. The topic lets a push service replace an undelivered push with
  a newer one.
- Pushes to one device are at least two seconds apart; events in between are
  covered by the next sync. A `404` or `410` from the push service removes
  the subscription; the app registers again on its next start.
- The server refuses endpoints that resolve to loopback, private or
  link-local addresses unless `HANASHI_PUSH_ALLOW_PRIVATE` is set, so users
  cannot make it send requests into its own network.

Calls push differently (see [Calls](#calls)): a call of two rings every
subscribed device of the one it calls, connected or not, at once, with
`{"type":"call","call":Call}` and `Topic: call<id>`; when it stops ringing, with
`{"type":"call_stop","call","conv","reason"}`.

On Android, a push while the app is closed starts it without its UI (Dart
entry point argument `--unifiedpush-bg`): it syncs once, shows notifications
and stops. Only one engine at a time holds the device's MLS state; if the
app is open, a push only asks it to catch up.

## Calls

Calls go through a [LiveKit](https://livekit.io) server beside this one, when
the operator set one up (`GET /integrations` says `"calls": true`, and
`"video": true` where calls may carry cameras and shared screens too). The
apps encrypt the audio and video end to end; [calls.md](calls.md) has the
design, the setup and the threat model. One call at a time goes on in a
conversation, and for now only when everyone in it is of this server.

| Method and path            | Body                             | Response                                                                                                                                                                                                                                                                                                                                                              |
| -------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /calls`              | `{"id": ULID, "conv", "video"?}` | `{"call": Call, "livekit": {"url", "token"}}`: joins the conversation's call, or starts one with that ID (so that a retry finds it again), a video call with `"video": true`. `403 not_a_contact` (a chat of two) or `not_verified`; `404` not a member, or `calls_off`; `409 calls_unavailable` (someone of another server), `409 call_ended` (that ID's call ended) |
| `POST /calls/{id}/decline` | `{}`                             | `{"call"}`: the one a call of two rings says no (`declined`). `409 not_ringing` for anyone else                                                                                                                                                                                                                                                                       |
| `POST /calls/{id}/leave`   | `{}`                             | `{"call"}`: this device hangs up. Before an answer, the caller hanging up cancels a call of two (`cancelled`)                                                                                                                                                                                                                                                         |
| `GET /calls`               |                                  | `{"calls": [Call]}`: the calls of the user's conversations going on, or ended in the last day                                                                                                                                                                                                                                                                         |
| `POST /livekit/webhook`    | LiveKit's event                  | LiveKit's webhooks, signed with the shared API secret (no session, no client level); `401` for any other                                                                                                                                                                                                                                                              |

`Call`: `{"id", "conv", "direct", "video"?, "startedBy", "startedDevice",
"startedAt", "ringUntil"?, "answeredAt"?, "endedAt"?, "reason"?, "version",
"participants": [{"user", "device", "joinedAt"}]}`, times in milliseconds.
`video`: started as a video call, so its devices start with their cameras on.
`reason` is `ended`, `declined`, `missed`, `cancelled` or `failed`. `version`
goes up with every change: apps keep the call with the highest.

- **Joining:** the token lets the device into the room named after the call,
  as `user/device`, to publish its microphone, camera, shared screen and the
  screen's sound, and to set its own attributes: `deafened` (`"true"`) while
  it plays nobody's audio, for the others to see. It may also send data
  messages, which the apps encrypt with the media's key: on topic
  `hanashi.speaking`, one byte, `1` once its voice gate lets its voice out
  and `0` once it stops, to everyone as it changes and to each newcomer while
  it is `1`. Whoever starts a call sends a `call` message to the
  conversation, its place in the chat.
- **Who is in it:** LiveKit says, by webhook, who joined and left. The server
  checks with LiveKit's room API every 15 seconds besides, as webhooks can be
  lost. A device that does not belong in a room (no longer a member, the call
  over) is put out of it.
- **When it ends:**
  - A call of two rings until `ringUntil` (45 s), then it is `missed`. It is
    answered once the other one's device gets in.
  - It ends once either side has no device in it; a group call once nobody is
    left.
  - A call nobody got into in 30 s `failed`.
- **Telling devices:** every change goes to the members' devices as a `call`
  frame. A call of two also rings by push, and stops ringing by push.
- **The media's key** in each epoch of the conversation's group is the MLS
  exporter's `"hanashi-call-v1"` secret, with the call ID as context, 32 bytes
  (see [calls.md](calls.md#encryption)).

## Ordering guarantee

The server commits events in `seq` order and publishes them live in that
order. That is what makes "jump the cursor to the newest seq" safe: once a
device has seen seq N, no event below N can appear later. The server enforces
this with a lock around every event-producing write, so **run one server
process per database**. Leases and epoch checks happen under the same lock.

## REST API

All bodies are JSON. Errors are `{"error": "<code>", "message": "..."}` with
an HTTP status code. A `502 server_unreachable` for a conversation another
server orders adds `"server": "<host>"`, the server that could not be reached
(older servers leave it out). Except where noted, requests need
`Authorization: Bearer <token>`. The key, MLS, inbox, verification, account
data and push endpoints are listed in their sections above.

`GET /server`'s `source` is where the server's source code is (an http(s)
URL), which apps offer its users: the AGPL asks whoever runs a changed server
for others to offer them its source. Servers before 1.0.0 leave it out.

| Method and path                                   | Body / query                                                                                           | Response                                                                                                                                                                     |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /server` (no auth)                           |                                                                                                        | `{"host", "version", "registration": "open"\|"invite"\|"closed", "maxUploadBytes", "minClient", "vapidKey", "source"}`                                                       |
| `GET /integrations`                               |                                                                                                        | `{"klipyApiKey"?, "calls"?, "video"?}`: the KLIPY API key for GIF search, if the operator set one; whether the server carries calls, and video in them (see [Calls](#calls)) |
| `POST /auth/register` (no auth)                   | `{"name", "password", "inviteCode"?, "deviceName", "platform"}`                                        | `{"userId", "token", "deviceId"}`                                                                                                                                            |
| `POST /auth/login` (no auth)                      | `{"name", "password", "deviceName", "platform"}`                                                       | same as register                                                                                                                                                             |
| `POST /auth/logout`                               | `{}`                                                                                                   | `{}`; ends this device's session                                                                                                                                             |
| `GET /devices`                                    |                                                                                                        | `{"devices": [{"id", "name", "platform", "createdAt", "lastSeenAt", "current"}]}`                                                                                            |
| `DELETE /devices/{id}`                            |                                                                                                        | `{}`; signs that device out and closes its socket                                                                                                                            |
| `GET /users/{userId}`                             |                                                                                                        | `{"id"}`, or `404 user_not_found`                                                                                                                                            |
| `GET /sync`                                       |                                                                                                        | snapshot: `{"cursor", "conversations": [{"conversation", "readUpTo", "messages": [SyncEvent], "moreHistory"}]}`                                                              |
| `GET /sync?since=&limit=`                         | `limit` ≤ 1000, default 500                                                                            | `{"events": [SyncEvent], "cursor", "more"}`                                                                                                                                  |
| `POST /conversations`                             | `{"id", "members": [userId], "direct"?, "mls": {...}}` (see [Membership changes](#membership-changes)) | ConversationInfo, a group of the caller and their contacts, or with `"direct": true` the direct chat with the one contact, which may be one they had; `403 not_a_contact`    |
| `GET /conversations/{id}/messages?before=&limit=` | `limit` ≤ 200, default 50                                                                              | `{"messages": [SyncEvent], "more"}`, oldest first                                                                                                                            |
| `POST /conversations/{id}/members`                | `{"user": userId, "commit": {...}}`                                                                    | ConversationInfo (groups only); `409 already_member`, `403 not_a_contact`                                                                                                    |
| `POST /conversations/{id}/leave`                  | `{}`                                                                                                   | `{}` (groups only)                                                                                                                                                           |
| `GET /presence`                                   |                                                                                                        | `{"mode"}`: the caller's own; see [Presence](#presence)                                                                                                                      |
| `PUT /presence`                                   | `{"mode": "auto"\|"focus"\|"invisible"}`                                                               | `{"mode"}`; see [Presence](#presence)                                                                                                                                        |
| `POST /conversations/{id}/read`                   | `{"upTo": seq}`                                                                                        | `{"readUpTo"}`; only moves forward. Apps use the `read` frame.                                                                                                               |
| `POST /messages`                                  | Envelope                                                                                               | `{"seq"}`. Apps use the `send` frame. `403 not_a_contact` in the direct chat of someone no longer a contact.                                                                 |
| `POST /messages/delete`                           | `{"ids": [messageId]}` (1–100)                                                                         | `{"deleted"}`. Drops the caller's own messages among `ids`, with everyone's key backup entries for them.                                                                     |
| `POST /media`                                     | raw bytes (encrypted)                                                                                  | `{"hash", "size", "mime"}`                                                                                                                                                   |
| `GET /media/{hash}`                               | optional `Range: bytes=...`                                                                            | the bytes; `206` for ranges, `416` if unsatisfiable                                                                                                                          |

Media can be downloaded by any signed-in user who knows its hash; without the
file key from the message, that yields only ciphertext. Downloads are served
with `X-Content-Type-Options: nosniff` and `Content-Security-Policy: sandbox`,
and clients must never open or execute a received file automatically.

## WebSocket frames

Every frame is a JSON object with a `type`. Requests carry a client-chosen
`rid` that the answer echoes.

| Direction        | Frame                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------ |
| client -> server | `{"type":"auth","token":"...","client":level}`, which must be first and arrive within 10 s                               |
| server -> client | `{"type":"ready"}`                                                                                                       |
| server -> client | `{"type":"event","event":SyncEvent}`                                                                                     |
| server -> client | `{"type":"inbox","item":InboxItem}`                                                                                      |
| server -> client | `{"type":"backup"}`: the key backup gained entries (see [Key backup](#key-backup))                                       |
| server -> client | `{"type":"trust"}`: the user's trust statements changed (see [Trust statements](#trust-statements))                      |
| server -> client | `{"type":"account_data","name":"..."}`: one of the user's account data blobs changed (see [Account data](#account-data)) |
| server -> client | `{"type":"call","call":Call}`: a call in one of the user's conversations changed (see [Calls](#calls))                   |
| client -> server | `{"type":"send","rid":"...","envelope":Envelope}`                                                                        |
| client -> server | `{"type":"commit","rid":"...","conv":"...","commit":{...}}`, answered with an `ack` carrying `seq`                       |
| client -> server | `{"type":"read","rid":"...","conv":"...","upTo":seq}`                                                                    |
| server -> client | `{"type":"ack","rid":"...","seq":n}` or `{"type":"ack","rid":"...","readUpTo":n}`                                        |
| server -> client | `{"type":"nack","rid":"...","error":"<code>","status":<http status>,"message"?,"server"?}`                               |
| both             | `{"type":"typing","conv":"..."}` (the server adds `"user"`; ephemeral, never stored)                                     |
| both             | `{"type":"presence",...}`: who is online, and whether this device is in use (see [Presence](#presence))                  |
| server -> client | `{"type":"error","error":"unauthorized"\|"session_revoked"\|"client_too_old"}`, then the socket closes                   |

The server pings every 30 s and drops connections that do not answer. A
device that falls far behind on reading is disconnected and catches up via
`/sync` after reconnecting.

## Federation

Users of servers that federate can be contacts across servers, have their
direct chats and be in groups together, with files, emoji verification,
typing and presence, as on one server. See
[Federation and alternate networks](federation.md) for what is left.

**Turning it on.** A server federates only once its operator sets
`HANASHI_FEDERATION=on`, and then only with the servers `HANASHI_FEDERATION_SERVERS`
lists (comma-separated), or with any server if it says `*`. Without one or the
other, the server does not start. It never federates with a host no other
server could have (localhost, an IP address, `.local`, one with a port), unless
`HANASHI_FEDERATION_RESOLVE` names it. With users of a server it does not federate
with, the API answers `404 other_server`. A request from a server it does not
list is answered `403 not_allowed` before anything else, its key not even
fetched; with federation off, `/federation/` answers `404 federation_off`.

**Finding a server.** The server of `name@example.org` answers at the address in
`https://example.org/.well-known/hanashi/server`, `{"server":
"https://chat.example.org"}`, or else at `https://example.org`. A server looks the
address up again after an hour, and does not connect to loopback, private or
link-local addresses it looked up. `HANASHI_FEDERATION_RESOLVE` (`host=url,...`)
gives addresses instead, for tests and private networks; it is the only way to
use `http://`.

**Server keys.** Each server has an Ed25519 key, made on first start:
`GET /federation/v1/key` answers `{"host", "keyId", "key"}`, where `keyId` is
`ed25519:` and the first 8 bytes of the key in base64url. Other servers fetch it
from the server's address, over TLS, when a request names a key ID they do not
have, at most once a minute per server.

**Requests.** Every request between servers is a `POST` under `/federation/v1/`
whose JSON body says `{"origin", "destination", "ts"}` (milliseconds) besides
what it asks. The headers `X-Hanashi-Origin`, `X-Hanashi-Key-Id` and
`X-Hanashi-Signature` carry a base64 Ed25519 signature of the raw body. The
signature covers the body alone, which names both servers and the time, so it
means the same whatever carries it. The receiver refuses with `401 not_signed` a
body for another server, more than 5 minutes off its clock, or not signed with
the origin's key, and with `403 not_allowed` one from a server it does not
federate with. Client levels and bearer tokens do not apply.

**Limits.** Each other server may make `HANASHI_FEDERATION_RATE` requests a
second (100 unless set), in bursts of ten seconds' worth, and fetch files at a
tenth of that. Over it, the answer is `429 too_many_requests` with
`Retry-After`, counted after the signature checks out, so no server can use up
another's share. At most 64 requests from all other servers are under way at
once; beyond that the answer is `503 busy`. A server's queue waits as long as
`Retry-After` says before sending again, and an app whose request was relayed
gets the `429` itself, to try again later. Keys of servers not seen before are
fetched at most 30 times a minute, so requests naming made-up servers cannot
make this one knock on many doors.

**Queries** are answered at once, for an app's request that waits for them: 10
seconds at most, or the app gets `502 server_unreachable`.

| Path            | Body                   | Answer                                                                                                                              |
| --------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `query/server`  | `{}`                   | `{"version", "features", "handingOver"?}`: what the server can do (see [Handing a conversation over](#handing-a-conversation-over)) |
| `query/user`    | `{"user"}`             | `{"user"}`, or `404 user_not_found`                                                                                                 |
| `query/keys`    | `{"user"}`             | As `GET /keys/users/{id}`                                                                                                           |
| `query/profile` | `{"user", "asker"}`    | As `GET /users/{id}/profile` for `asker`, a user of the server that asks                                                            |
| `query/claim`   | `{"asker", "devices"}` | `{"packages"}`: as `POST /keys/packages/claim` for `asker`                                                                          |

An app asks its own server as always: `GET /users/{id}`, `GET /keys/users/{id}`
and `GET /users/{id}/profile` of a user of another server go through these, and
`POST /contacts/requests` with one asks `query/user` first. A claim of
devices of another server's users is sent on to their server, which keeps
`MayClaimPackagesOf` (`403 not_a_contact`).

**Transactions** carry what happened, in order: `POST /federation/v1/send` with
`{"stream", "items": [{"id", "type", ...}]}` answers `{"refused": [{"id", "error"}]}`.

- A server writes an item in the same database transaction as the change it tells
  of, and keeps it until its destination has it. It sends at most 100 at a time,
  in `id` order, so each destination gets them in the order they happened. After
  a failure it waits a second, doubling up to an hour. Items still waiting after
  30 days are given up on.
- `id`s grow within a `stream`, which names the sender's run of IDs; it changes
  only if the sender's database starts again. The receiver applies a
  transaction's items in one database transaction, together with how far it got,
  so an item sent again after its answer was lost is skipped: each counts once.
- An item the receiver cannot take (a user it does not have, a `from` not of the
  sender's host, a type it does not know) is refused, and not sent again.

| Item                | Fields                                                                            | Says                                                                |
| ------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `contact.request`   | `from`, `to`                                                                      | `from` asks `to`                                                    |
| `contact.accept`    | `from`, `to`                                                                      | `from` said yes to `to`                                             |
| `contact.cancel`    | `from`, `to`                                                                      | `from` took their request to `to` back                              |
| `contact.remove`    | `from`, `to`                                                                      | `from` and `to` are no longer contacts                              |
| `user.keys_changed` | `user`                                                                            | `user`'s keys changed; their contacts' devices fetch them again     |
| `messages.deleted`  | `user`, `ids`                                                                     | `user` deleted these messages of theirs for everyone: copies go too |
| `conv.event`        | `conv`, `seq`, `prev`, `event`                                                    | An event of a conversation the sender orders (below)                |
| `inbox.welcome`     | `user`, `device`, `conv`, `epoch`, `data`, `state`?, `senderUser`, `senderDevice` | A Welcome for a device of the receiver                              |
| `inbox.message`     | `to`, `device`?, `messageType`, `data`, `senderUser`, `senderDevice`              | A device message (emoji verification) for `to`'s devices, or one    |

`from` and `user` are users of the sending server, `to` one of the receiving.

**Contacts across servers.** Each server keeps how the two stand towards each
other: what its own user does it decides, the other's it takes from items. The
rules are those of [Contacts](#contacts), and what comes of a request is decided
by the server of the one asked. Declining is never told; a request to someone
who blocked the asker, or again after a no, reaches nobody. Blocking a contact
tells their server only that the contact ended, and blocking someone one had
asked takes the request back. A request that crosses one's own is a yes, so two
who ask each other at once become contacts. A yes to a request no longer
standing (taken back, or the asker blocked them since) is answered with
`contact.remove`. A server keeps at most 1000 unanswered requests from the users
of one other server (`too_many_requests`).

**Users of other servers** get rows like the server's own users, with no
password: sign-in takes names of the server's own host, so they never can.
User IDs have at most 128 characters.

### Conversations across servers

**Its hub.** One server orders each conversation, as one server orders all of
them without federation: the lease, the epoch, the GroupInfo, the sealed state
and the order of events are its. The servers of its other members keep a copy
of the conversation, which apps use as any other.

- **A direct chat** of two users of different servers is ordered by the server
  of the one whose ID sorts first. Both servers work it out alike, so two who
  start their chat at once cannot make two.
- **A group** is ordered by its creator's server, which is where it is made.
- **While its hub cannot be reached,** a conversation cannot change: no
  messages, commits or members. Apps keep what is sent to it, say which server
  they wait for (see [Sending](#sending)), and send it once that one is back.
- **A hub can hand a conversation over** to the server of some of its other
  members, which orders it from then on: see
  [Handing a conversation over](#handing-a-conversation-over).

**Events, in the hub's order.** The hub sends each event of the conversation
that its members see to the servers of its members of other servers:
`conv.event {conv, term?, seq, prev, event: {type, ts, data, msgId?, sender?}}`.
`seq` is its seq at the hub, and `prev` that of the conversation's previous such
event there in the same term (0 for the first). `term` counts the times the
conversation moved to another hub (absent: 0); each hub numbers the events of
its term. Events for one user only (read markers) stay where they are.

- **On the copy:** the server appends the event to its own log, with its own
  seq, and wakes its users as the hub does its own.
- **A repeat** (a `seq` it has) changes nothing.
- **A gap** (a `prev` it does not have) is filled from the hub with
  `query/conv.events {conv, term?, since, except?}`, which answers
  `{"events": [{term?, seq, type, ts, data, msgId?, sender?}], "more"}`: the
  events after the one `since` of `term`, in order, term by term, but for those
  of the types `except` lists.
- **A new copy** starts with the conversation's `conversation_created`, if
  that server is its hub by the rules above. When one of the receiver's users
  is added to a conversation it has no copy of, it fetches the conversation
  from its start (`conv.events` from 0), from the server that told it, which
  may be a later hub than the first.
- **Who of the receiver's users is in it** follows `member_added` and
  `member_removed`, with one rule of its own: a user of the receiver is in a
  conversation only if whoever made it or added them is their contact, on the
  receiver's own rows. Otherwise the receiver leaves them out, whatever the hub
  says.
- **History only:** while none of the receiver's users are in a conversation,
  its messages are kept as history and nothing else is. So someone who joins
  reads what was said before (history and snapshots have it, as on one server),
  but none of it reaches them as new events: their devices hear of the
  conversation from the event that adds them on.
- **Welcomes** for devices of the receiver's users come as `inbox.welcome`,
  before the event that adds them, as on one server. The receiver takes one from
  a contact of the user's, from one of the user's own devices, or for a member
  of a copy it has from that hub.

**What apps ask of a copy.** Apps ask their own server as always. For a
conversation another server orders, their server checks that they are a
member, and relays the request to the hub as a query naming the acting `user`
(of the server that asks) and `device`, which that server vouches for:

| App request                                                           | Query to the hub                         | Answer to the app                              |
| --------------------------------------------------------------------- | ---------------------------------------- | ---------------------------------------------- |
| `POST /messages`, the `send` frame                                    | `query/conv.message {envelope}`          | The message's seq on the app's own server      |
| `POST /conversations/{id}/lease`, and its `DELETE`                    | `query/conv.lease`, `query/conv.release` | As the hub answers                             |
| `POST /conversations/{id}/commits`, the `commit` frame                | `query/conv.commit {commit}`             | The commit's seq on the app's own server       |
| `GET /conversations/{id}/group-info`                                  | `query/conv.group_info`                  | As the hub answers                             |
| `PUT /conversations/{id}/state`                                       | `query/conv.state`                       | As the hub answers                             |
| `POST /conversations` with `"direct"`, if the hub is the other server | `query/conv.create {request}`            | The chat, once the copy has it                 |
| `POST /conversations/{id}/members`                                    | `query/conv.add_member {member, commit}` | The conversation, once the copy has the commit |
| `POST /conversations/{id}/leave`                                      | `query/conv.leave`                       | `{}`, once the copy has it                     |

- **Seqs on the app's own server:** an answer with a seq comes once the copy has
  the hub's event, which the hub sends at once. The hub answers where the event
  is in the conversation's order, `{"term", "seq"}`, for the copy to wait for.
- **The hub's refusals pass through unchanged:** `epoch_mismatch`, `lease_held`,
  `lease_invalid`, `not_a_contact`, …
- **No clear answer:** if the hub cannot be reached, the app gets
  `502 server_unreachable`. If the hub took the request but the copy has not
  heard of it within 10 seconds, it gets `504 no_clear_answer`. Either way the
  app goes on as after any answer that did not come: it sends the message again
  with its ID, settles the commit from the event log, or asks for the chat again.
- **Who checks what:** the hub takes the server that asks at its word on the
  device being verified, and, when it relays an addition, on whoever is added
  being a contact of whoever adds (the hub may have no rows of the two). It
  also takes the word of a member's server on whose a device is, for a
  Welcome. Contact gates it can check, it checks on its own rows.
- **Welcomes first:** when someone is added, the hub sends their devices'
  Welcomes before `member_added`, so their server has them before it hears.

Deleting messages for everyone also removes the copies: the sender's server
tells the servers of the other members (`messages.deleted`). When a member of
another server leaves, their server hears of it too, and gives them their own
copy of `member_removed`; once none of its users are in a conversation, the hub
sends it nothing more.

### Handing a conversation over

A hub hands a conversation over to the server of some of its other members,
which orders it from then on, so that the conversation goes on without the
server it started on:

- **By itself,** once none of its own users are in a group that has members on
  other servers.
- **Everything it orders** that has members elsewhere, direct chats too, when
  its operator sets `HANASHI_HAND_OVER=all`, before shutting it down. Its own
  users stay in what it hands over, which their server relays as for any
  conversation another server orders.

Only the hub decides, in its order of events, so two servers never both
order a conversation. Without the hub, a conversation cannot move: it waits
for the hub to be back.

**Which server.** The hub asks every other member's server what it is,
`query/server`, answered with
`{"version", "features": ["hub-move"], "handingOver"?}`. Servers from before
moves answer it with an error. If any of them lacks `hub-move` or cannot be
reached, the conversation stays for now, and the hub tries again later (after
10 minutes, doubling up to 6 hours). Of the others that are not handing over all
they order themselves, it chooses the one with the most of the conversation's
members (of two with as many, the host that sorts first).

**Ready.** The hub asks that server `query/conv.handover {conv, term}`, again
and again, until it answers `{"ready": true}`; if it is not ready within a
minute, or refuses, the hub goes on to the next. A server is ready once its copy
of the conversation is of that hub and term, some of its users are in it, and
it holds the conversation's whole order, which it has to give to servers that
join later. Its copy lacks what came while none of its users were in it but
messages, which a copy always keeps: it takes that from the hub
(`conv.events` with `"except": ["message"]`), and answers `{"ready": false}`
meanwhile. It answers `409 not_ready` while its copy is of another term, and
`409 no_members` if none of its users are in it.

**The move.** In one step, the hub ends its term with a `hub_moved` event,
`{hub, term, epoch, groupInfo, state?}`: the next hub, the term it orders, and
the epoch, GroupInfo and sealed state, which only a hub keeps. It is the last
`conv.event` of the term, to the servers of all members. It is the servers'
own: no app ever gets it, and apps need not know a conversation moved. The
hub's lease ends with it.

- **Each copy** switches at that event, so all switch at the same point of the
  conversation's order: from then on it takes the events of the new term from
  the new hub, and relays to it. The new hub takes the GroupInfo and state.
- **An event of a later term** than a copy knows of comes before the copy has
  heard of the move. The copy catches up from the hub it has, which says where
  it moved; or, if that one cannot be reached, from the server that sent the
  event, which has every move since in its order.
- **An event of a past term** changes nothing.
- **A Welcome** from another server than the hub a copy has is taken as for a
  conversation it has no copy of: from a contact of the user's, or from one of
  their own devices.

**After the move,** the old hub answers what is relayed to it about the
conversation with `503 conv_moved`, as does the new hub until it has the
`hub_moved` itself. Apps hold what they sent and try again (see
[Sending](#sending)); by then their server relays to the new hub, which it also
learns of at once from the old one, told so. The old hub still gives copies
that missed the move the events of the terms it ordered, `hub_moved` included.
A server from before moves cannot join a conversation that moved.

### Files, verification, typing and presence across servers

**Files** stay on the server they were uploaded to, which the `MediaRef` names
(`host`). An app asks its own server as always, saying where the file is:
`GET /media/{hash}?host=example.org`.

- **The first time,** the reader's server fetches it from that server with
  `POST /federation/v1/media {hash}`, which answers the file's bytes. It passes
  them on to the app as they come, and keeps them only if they are the file of
  that hash and fit its own upload limit.
- **From then on,** it serves its copy, also while the other server is down.
  One fetch of a file goes at a time; whoever asks meanwhile gets the copy once
  it is kept.
- **Who may fetch:** a server gives a file it has to any server it federates
  with. Knowing the hash is what lets anyone have it, as for its own users.

**Device messages** for emoji verification go to devices of another server's
users through the item queue, so they arrive in order: `inbox.message`. The
sender's server checks that the two share a conversation, and so does the
receiver's, on its own rows. The receiver puts the message in the inbox of
`device`, or of each of `to`'s devices. In `POST /inbox/send`, each recipient
of another server counts as one delivered. Trust statements stay with the
signer's own server.

**Typing and presence** matter only now: `POST /federation/v1/ephemeral {typing?:
{conv, user}, presence?: {user: status}}` is signed like any other request, but
never stored or sent again.

- **Typing** goes from the typist's server to the servers of the
  conversation's other members, whichever server orders it. The receiver passes
  it on if the user is a member of its copy.
- **Presence:** a server tells the servers of a user's peers when their status
  changes (invisible is offline), and every 2 minutes repeats the statuses of
  its users who are not offline. The receiver keeps a status for three repeats,
  only of users who share a conversation with one of its own. After that, or
  when told so, the user is offline again, which it tells its users.

## Threat model

**Protected from the server** (and anyone who reads its database): message
text, captions, file contents, file names, types and dimensions, reactions,
replies, edits, display names, group titles and descriptions, profile and group
pictures, status messages, bios and birthdays, and the links, pages, videos and
GIFs of link previews.

**Not hidden:** who talks to whom and when, who asked, accepted or blocked whom,
conversation membership, user IDs, how large messages, files, profiles, group
states and account data are, roughly (they are [padded](#padding)), when a profile or a group's
state changed and by whom, hashes of group documents (salted), device lists and which devices are
verified, whom a user verified (trust statements are signed, not encrypted),
read markers, typing notices, who is online, idle or in focus (also to the
people a user shares a conversation with, unless they are invisible), and
which messages a user's devices have read
(the message IDs in the key backup), and the names of a user's account
data. Reactions, edits and deletions are encrypted
messages like any other; the server sees only that a
message was sent, and which of the sender's messages they asked it to
delete. KLIPY sees the IP address of a device that searches for GIFs or
loads a GIF sent from KLIPY, and which GIF, but no user ID. The site behind a
link sees the IP address of the device writing a message with it, while it makes
the preview (unless previews are off), but not who reads it, except someone
who chose to load the link's video or GIF from it. The push
service a device uses (its
UnifiedPush distributor's server, or Google for FCM) sees when that device
is woken, but not by whom or why.

**Other servers**, when federating, learn of the contact requests between their
users and this server's, and how they are answered, except declines and blocks,
which look like nothing. They can look up any user's keys, as any signed-in user
can. A server cannot speak for users of another host: each item is signed by
its server, and may name only users of that server as the ones acting. What a
dishonest server can do with its own users is what any server can. In a chat
or group across servers, every member's server sees what a server sees of a
chat: who is in it, when they write, and how much. A hub cannot put a user of
another server into a conversation by someone who is not their contact: their
server leaves them out. The other server also learns when its users'
chat partners are online or typing, as they do. It keeps a copy of the files
sent there, encrypted like everything else. The hub orders it, so it can withhold or delay
what either side sends, as any server can for its own users. It cannot read or
forge messages, or add anyone the members' devices would not take.

**What a malicious server cannot do:**

- Add a reader to a conversation. New users enter only through a commit by an
  existing member, who adds the target's devices whose records are signed by
  the identity key that member pinned. Devices join by external commit only
  for users already in the group, and only with a verified record.
- Forge or alter messages. MLS authenticates the sender's leaf, the header
  must match it, and the content is bound to the header and to the hash in
  the MLS message.
- Make it look as if a member added someone, left, or created the group. Such
  lines come from that member's own `member` message; what only the server
  says shows as its word.
- Swap a file. Its hash and key travel inside the encrypted message.
- Pass an emoji verification by substituting keys, or forge or undo a
  verification (see [Trust statements](#trust-statements)).
- Forge a profile or bring an old one back (see [Profiles](#profiles)), or bring
  back old [account data](#account-data).
- Change what members who applied a group's commits take its name, description or picture to
  be, nor read it (see [Group state](#group-state)).
- Make someone a contact in the eyes of the user's devices, or add them to a chat
  of two with a stranger (see [Contacts](#contacts)).

**What it can do:**

- Withhold or delay messages, commits or Welcomes (denial of service).
- Show a new identity key for a contact. On first contact this is trust on
  first use, and for a contact the user has not verified, the client takes
  the new key with only a notice in the chat. Verifying the contact with
  emoji rules this out: then messages wait until the user verifies them
  again or accepts the change.
- Keep a new trust statement from the user's other devices, which then do not
  show the contact as verified yet.
- Refuse leases or commits. Clients then cannot change the group, but they
  never fork from each other.
- Withhold a profile, or a group's state from someone who joined by themself, who
  then shows it without a name; a commit or a member fills it in.
- Refuse contact requests, or claim a request was accepted while it was not; that
  shows only as something that does not happen, as the user's own list decides.
- Together with a member, show a new device a false name for a group, until the
  next commit. Together with a stranger, bring a user into a group holding one of
  their contacts, by claiming that contact invited them.
- For a device with no contact list after a reset of the account's keys, say who
  the user's contacts are (see [Contacts](#contacts)).
- Together with a member, show someone that member adds messages from before
  they joined that were never sent: those are read with keys the member
  shares (see [Sharing history](#sharing-history)), not checked by MLS.
- Keep the ciphertext of messages deleted for everyone (it still cannot read
  them). Deleting is a request: devices of members who already read a
  message forget it, but a modified client, or a person, can remember it.

**Device compromise:** someone holding a device's keys reads what that device
can read until the device is removed or rotates its keys (see
[Key rotation](#key-rotation)). Every verified device holds the user's
identity key, so a stolen device can verify new devices until the user resets
encryption. The app's local database, which holds decrypted messages, is
encrypted at rest with a random key the device keeps with its other secrets
(the system keyring); files it decrypted, cached beside it, are not yet.

## Forward compatibility

Servers federate for contacts, direct chats and groups (see [Federation](#federation)),
but there are no off-grid transports yet. These properties let federation come
without breaking changes, and are kept so that such transports will not need any
either (see [Federation and alternate networks](federation.md)):

- `name@host` IDs are unique across servers, and the full ID is part of every
  credential, signature and message's associated data, which is what lets
  users of other servers be contacts and share conversations.
- The server never reads message content; MLS commits, Welcomes and
  application messages are opaque to it, so any relay can carry them. Their
  order is another matter: each group needs one server to decide it.
- Client-generated IDs and the outbox make a retried send idempotent, which a
  slow store-and-forward link will rely on.
- Media is addressed by its hash, so any store can serve it, and the receiver
  can check what it got.
