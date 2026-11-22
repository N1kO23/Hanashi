# Federation and alternate networks

Where Hanashi stands on servers talking to each other and on networks other
than the internet, and what to keep in mind until then. This is a design note,
not a protocol. The protocol itself, including what federation does so far, is
in [protocol.md](protocol.md#federation).

## Federation

### What is built

Round 1, the foundation and contacts:

- **Finding a server** through its host's `/.well-known/hanashi/server`, or the
  host itself.
- **Server keys:** each request between servers is signed by its server's
  Ed25519 key, over the body alone, so the signature does not depend on HTTPS.
- **Queries** answered at once, and **transactions:** items stored with the
  change they tell of, sent in order, retried, and counted once.
- **Users of other servers** in the database, as rows without a password.
  User IDs are limited to 128 characters, the size of every column that holds
  one.
- **Contacts across servers:** asking, answering, taking back, removing and
  blocking, with the same rules as on one server. Looking up keys, and hearing
  when they change.
- **In the app:** a user of another server is named by their whole ID until
  their own name is known, so `alice@a` and `alice@b` never look alike.
- **Off unless turned on**, and then only with the servers listed (or with any,
  when asked for with `*`).

Round 2, direct chats:

- **A hub for each chat:** the server of the user whose ID sorts first, so two
  who start their chat at once cannot make two.
- **The other server keeps a copy.** It takes the hub's events in order, fills
  any gap from the hub, and relays its users' messages, leases, commits, group
  info and state to the hub.
- **Welcomes and key package claims across servers**, deletions of messages
  for everyone, and profiles through the shared chat.

Round 3, the rest of a chat:

- **Files** stay on the uploader's server, which their `MediaRef` names. The
  reader's server fetches a file once and keeps it.
- **Emoji verification** across servers, through the item queue.
- **Typing and presence**, best effort: sent once, never stored, with statuses
  repeated now and then and forgotten when they stop.

Round 4, groups, ordered by the creator's server:

- Copies that gain and lose members as the hub says, except that a server keeps
  out its users added by someone who is not their contact.
- A server that joins a group gets its past messages as history only, never as
  new events.
- Adding and leaving relayed to the hub; Welcomes reach the new member's server
  before the event that adds them.

Round 5, moving to another hub:

- **A hub hands a conversation over** to the server with the most of its other
  members: by itself once none of its own users are in a group, and everything
  it orders with `HANASHI_HAND_OVER=all`, before its operator shuts it down.
  Only the hub decides, in its order of events, so two servers never both
  order a conversation.
- **Terms:** each move starts a new term of the conversation's order, which
  the new hub numbers. Copies switch at the event that ends a term, and catch
  up across terms.
- **The whole order at every hub:** before taking over, the new hub takes from
  the old one what its copy lacks, so that it can give a server joining later
  everything from the start.
- **In the app:** a conversation whose hub cannot be reached says which server
  it waits for, and holds only its own messages: the others go on.

### What already fits

These were in place before federation, which needed no change to them:

- **Identities.** The full `name@host` is in MLS credentials
  (`<userId>/<deviceId>`), in each message's associated data, in trust
  statements and in emoji verification. Remote users need no new keys.
- **Distrust of the server.** Clients check every leaf against pinned identity
  keys, and take a Welcome only if it traces back to someone on the user's own
  encrypted contact list. A dishonest remote server meets the same checks as a
  dishonest home server.
- **Opaque data.** Message content, commits, profiles and group state are all
  encrypted or signed by clients, so servers only carry them.
- **One server per client.** A device talks only to its home server, so remote
  users can use the same API paths, with the home server relaying. Account data,
  key backup, secret storage and push stay at home unchanged.
- **Local `seq`.** A user's read markers go only to their own devices, so no
  server's `seq` numbers reach another server's users.
- **Host and address are separate.** `alice@example.org` can be served from
  `chat.example.org`, as `HANASHI_HOST` is not the address clients connect to.
- **Contact gates.** The recipient's server enforces them, which is the side
  that should.
- **Contacts and chats are separate steps.** Accepting a request makes two people
  contacts; their direct chat is started after that, by either of them.

### What is left, and what to know

No client protocol break was needed for any of this. What remains:

- **Moving without the hub.** A conversation moves only when its hub hands it
  over. While the hub cannot be reached, nothing in the conversation can change,
  and nothing can move it. A failover, the other servers agreeing on a new hub
  without it, could build on the terms that moves use.
- **Spam with any server allowed.** Each other server's requests are limited by
  rate, file fetches more so, and at most 1000 unanswered contact requests come
  from the users of one server. With `HANASHI_FEDERATION_SERVERS=*`, a server can
  still make many names for itself; a list keeps those out.
- **Moving between servers.** This means a new identity, because the host is
  part of the ID. That follows from `name@host`, and should be a known choice.

Known limits of what is built:

- **IDs unique across the whole database.** `msg_id` and `device_id` are, so a
  remote server could collide with them on purpose. A copy goes without a
  message whose ID is taken, and a device ID taken stays its first owner's.
- **What the hub takes on trust.** A member's server vouches that its user's
  device is verified, and, when relaying an addition, that whoever is added is
  a contact of whoever adds. The added user's own server checks that again
  before letting them in.
- **What a later hub says of the start.** A server that joins a conversation
  after it moved takes its whole order from the hub it is at now, and cannot
  check it with the first hub, which may be gone. Its users still get in only
  through a contact, and devices still check each Welcome.
- **Servers from before moves** can neither follow a conversation that moves (it
  stays where it is while one of them has members in it) nor join one that
  moved.

### Why each conversation has a hub

MLS needs one order of commits. On one server, the server gives it: the commit
lease, the epoch check and the event log. Across servers, one server does that for
each conversation, its **hub**: it keeps the lease, the epoch, the GroupInfo and
the sealed state, and gives out events in order. The servers of the other members
follow that order in their own event logs, with their own `seq`. The IETF's MIMI
work on messaging interoperability uses the same model.

A conversation ID does not say which server is its hub: each server keeps that
beside the ID, so a conversation's ID, which is also its MLS group ID, never
has to change.

### How servers talk

What happened goes from server to server as **items**: stored with the change
they tell of, sent in order, retried until they arrive and counted once, and
signed by the sending server over the body alone, so they mean the same however
they travel. What an app waits for goes as a **query**, answered at once: looking
up a user, their keys or key packages, a message, lease or commit for the hub, or
a file. Typing and presence, which matter only now, are told once and never kept.
Items would carry over to a slow or disconnected link as they are; queries would
have to wait as items do (see [Alternate networks](#alternate-networks)).

## Alternate networks

There are two separate problems.

### Reaching your server over another network

Tor, I2P, Yggdrasil, or Reticulum carrying IP. **This is close.** The ID format
accepts `.onion`, `.b32.i2p` and hash-like hosts, and `ApiClient` already takes
an `http.Client`. What is missing:

- `SocketClient` calls `WebSocketChannel.connect` directly.
- Link previews and KLIPY connect directly, which would reveal the user's IP
  address unless they go the same way.
- The 20-second API timeout and 30-second leases assume a fairly quick network.

### Low-bandwidth or disconnected networks

Meshtastic, or Reticulum over LoRa. **This is far off.**

- A short text comes to about 700 bytes after JSON, base64 and the two layers of
  encryption (an estimate, not a measurement). Meshtastic carries about 230 bytes
  per packet. A commit with its GroupInfo, state and Welcomes runs to kilobytes.
- A lease needs a round trip within 30 seconds.
- MLS needs one order of commits, so a group split in two forks. Peer-to-peer
  without any server does not fit this design.

The way there is federation: a small server on the local network is the home and
the hub for the people there, and exchanges events with other servers over the
slow link. Clients reach it over Wi-Fi or similar, and work as they do today.
Items already travel that way; queries, which wait for an answer, do not (see
[How servers talk](#how-servers-talk)).

## Rules for protocol changes until then

- Do not put a `seq` in anything one user sends another, or into encrypted
  content. It belongs to one server.
- Do not treat a device ID or conversation ID alone as naming something that can
  be trusted everywhere: any server could claim one.
- Keep new fields in encrypted content optional, and keep what later versions
  added (as group documents do with `extra`).
- Put the full `name@host` in anything signed or authenticated.
- Do not make clients depend on two things a server does in one transaction if
  they could arrive one after the other instead.
