# Calls

Hanashi's calls go through [LiveKit](https://livekit.io), an open-source
media server that runs beside the Hanashi server as a service of its own. The
audio and video are end-to-end encrypted by the apps, with keys from the chat's
MLS group: LiveKit forwards them without being able to hear or see them, and
the Hanashi server never handles them at all.

- A chat of two rings, like a phone call: a voice call, or a video call. A
  group has a drop-in call: anyone in it can join while it goes on.
- In any call, anyone can turn their camera on, or share a screen (see
  [Video and screen sharing](#video-and-screen-sharing)).
- One call at a time in a chat, and calls only between people of the same server
  for now (see [Later](#later)).

## How it fits together

```
App ──REST/WebSocket──► Hanashi server ◄── webhooks ── LiveKit
 │                       signs join tokens               ▲
 └──────── WebRTC audio, encrypted by the apps ──────────┘
```

- **The Hanashi server** keeps each chat's call: who started it, whether it
  rings, was answered or ended, and which devices are in it. It alone gives out
  the tokens that let an app into the call's LiveKit room (a JWT signed with the
  API secret it shares with LiveKit), and only to members of the chat.
- **LiveKit** tells the server who gets in and out of its rooms, by webhooks
  signed with the same secret. Webhooks can get lost, so the server also asks
  LiveKit who is in each room every 15 seconds.
- **The apps** hear of calls from the server (a `call` frame, a push, or
  `GET /calls` when they connect), never from LiveKit. Whoever starts a call
  also sends a `call` message to the chat: the call's place in it, with what
  became of the call (missed, declined, how long it lasted).

See [protocol.md](protocol.md#calls) for the wire format.

## Encryption

The key of a call's audio in each epoch of the chat's MLS group is

```
K = MLS-Exporter("hanashi-call-v1", context = UTF-8(call ID), 32 bytes)
```

(RFC 9605, section 5.2, describes deriving SFrame keys from MLS the same way.)
Every member device derives the same key, and nobody else can.

- **When keys are taken:** a device derives the key again whenever the group
  moves to an epoch everyone agrees on: another member's commit applied, its own
  commit accepted by the server, or a join. Never while its own commit is
  unsettled: that epoch might never be anyone else's.
- **How LiveKit uses them:** LiveKit's end-to-end encryption, in shared-key
  mode, holds the keys by index (`epoch % 16`). Each frame says which key it is
  encrypted with.
  - A new key is used for decrypting at once.
  - It is used for sending 2 seconds later, so that devices a commit behind
    don't drop out of hearing.
- **Defaults hardened:**
  - **No ratchet:** keys never move on by themselves.
  - **No early frames:** nothing is sent or played before its key is set, and
    the microphone stays muted until the device's audio is encrypted.
  - **Random marker bytes, per call:** frames ending with them would pass
    unencrypted.
  - **The server's trailer is ignored:** LiveKit's server can send a trailer
    that makes receivers play frames ending with it without decrypting.
    LiveKit uses it for the second of silence it adds once someone mutes.
    Those frames fail to decrypt and are dropped, so the warning that someone
    can't be heard counts only unmuted audio that has not decrypted for 2
    seconds.
  - **Unencrypted audio is refused:** a track that comes unencrypted is never
    played.
- **Each device is its MLS credential:** a device's identity in a room is
  `user/device`, the same as its MLS credential, so the app can tell who is
  there.

### What the servers learn

- The Hanashi server learns who calls whom, when, for how long, and from
  which devices. It can make a phone ring, or end a call, but not hear it or
  put sound into it.
- LiveKit learns the same, the devices' IP addresses, and who speaks when (from
  the audio level in each packet, which WebRTC does not encrypt, and from when
  devices send their encrypted messages that say so). It cannot hear what is
  said.
- Of video, LiveKit learns whose camera is on and who shares a screen, and the
  video's size (the first bytes of each VP8 frame stay readable, for LiveKit to
  route them), frame rate and bitrate. It cannot see what is shown.
- LiveKit also learns who is deafened: a device says so in its attributes, for
  the others to show.
- **Known limitation:** all devices in a call share one key per epoch, so a
  member's device could forge another member's audio. Keys per sender (derived
  from `K` and the sender's identity) would close that.

## Video and screen sharing

- **Cameras:** anyone can turn theirs on in a call. A video call in a chat of
  two starts with the caller's camera on, rings as a video call, and answering
  it turns the camera on too (one tap turns it off).
- **Sharing a screen:** from the call. Where the system lists screens and
  windows (X11, Windows, macOS), the app shows them to pick from. On Wayland
  the system's own dialog asks instead, once, for a screen or a window: the app
  keeps a desktop portal session of its own for it (`app/linux/webrtc`), as the
  WebRTC library flutter_webrtc brings asks the portal for screens only, and
  twice. Android asks each time, for one app or the entire screen (see
  [Android](#android)). Not on iPhones yet.
- **While you share,** the share button is green (it stops sharing), and a
  small tile, "Your screen", shows what goes out. It shows large only when you
  pick it, as it may show itself.
- **A shared screen's sound** (Linux): on when sharing starts. The sound button
  beside the share button turns it off and on, and its menu picks whose sound
  it is: all apps, or one of the apps playing. It never has Hanashi's own
  sound, so nobody hears themselves. Where a share could have sound but has
  none, the sound button is greyed out and says why (a call server not updated
  yet, for one).
  - It is taken from PipeWire by the app itself (`app/linux/webrtc`): every
    app's playback stream, except Hanashi's and that of any program that
    takes in what others play (it has a sink of its own, or records one's
    monitor), as EasyEffects, a loopback or a filter chain do. Their output
    has every app in it, the call too.
  - flutter_webrtc's own would record the default output, the call included.
  - It goes as one channel (mono) at 96 kbps: LiveKit's Flutter client sends no
    stereo.
  - It goes out as the apps play it. Echo cancelling, noise suppression and gain
    control are for the microphone and never touch it (checked with test tones
    through LiveKit). WebRTC does apply each sent track's settings to the one
    processor the microphone uses. So the screen's sound asks for the
    microphone's own settings: asking for none turned the microphone's
    processing off for as long as the screen was shared.
  - Your microphone also picks up what your speakers play: with speakers
    rather than headphones, the others hear the screen's sound twice.
  - The others hear it only while they watch the screen. They can turn its
    sound off for themselves (its speaker button), or set how loud it plays
    (see [The apps](#the-apps)), and deafening turns it off too.
  - Phones play someone's shared screen's sound as media, as a video app does,
    at the media volume (`StreamSound.kt`). Everything WebRTC plays goes the
    call's voice way, which phones process for speech, spoiling music. Some
    phones' echo cancelling doesn't cover media. With the speaker and the
    microphone on, the sharer may then hear their sound come back; muted, or
    with headphones, it can't.
  - Not yet on Android, Windows or macOS.
- **Where it shows:** in the call's chat, above the messages: everyone in a
  grid, as on Discord. Clicking someone, or a shared screen, shows them large
  with the others beside; clicking again goes back to the grid. Nothing goes
  large by itself, someone else's shared screen neither, except one just
  watched. Its height can be dragged. Elsewhere in the app, the call bar shows
  the call as before.
- **A call without video** has the grid too: the call bar's grid button opens
  it in the call's chat, with everyone's picture and who speaks, and its arrow
  button hides it again. On phones the button opens the call's own view, with
  everyone in a grid.
- **Fill the window and full screen** (desktops): the call's video can fill the
  window, or the whole screen (the Full screen button, F11, or a double click
  on someone, who then shows large; Esc goes back to where it was). The large
  video then takes all the room, with the others and the buttons over it. These
  fade out after 3 seconds without the mouse moving, and come back when it
  moves.
- **On phones** (and in narrow windows), a call with video fills the screen
  instead: a shared screen watched or a camera large, edge to edge, and your
  own camera small in a corner.
  - Over it are the bar at the top, the others in a strip (beside, with the
    phone held sideways) and the buttons.
  - A tap on the video takes all of these away, with Android's own bars, and
    brings them back. They also go by themselves after 5 seconds untouched.
    While they are away, a tap only brings them back, so nothing is pressed by
    mistake.
  - Tapping someone in the strip shows them large. A shared screen shown large
    zooms with two fingers, or a double tap.
  - The full-screen button turns the phone the video's way (sideways for a
    wide one) with nothing over it. Back leaves full screen first.
  - The arrow at the top, or Back, puts the call's view away for the call bar,
    and tapping the call's name there brings it back.
- **Watching a shared screen is up to each one,** as on Discord: someone's
  share shows as a tile with a Watch button, and none of it comes, picture or
  sound, until it is pressed. The eye button on a watched screen stops watching
  it. A share watched ends with it: the next one is watched only once asked
  again.
  - Every track is subscribed to, as LiveKit does by itself, and an unwatched
    share's are disabled: LiveKit's server sends none of their media. A share
    started during the call is disabled as soon as LiveKit tells of it. One
    going on as a device gets into the call comes for a moment, until LiveKit
    hears it isn't watched.
  - The one watched comes even while it isn't on screen (the call's view put
    away), until watching stops.
- **Bandwidth:** LiveKit sends each device only the video it shows, no bigger
  than shown (adaptive stream), and a camera is sent in three sizes (simulcast)
  so that each gets the one it needs. A shared screen goes in one size, as set
  in Settings, and only to those watching it.
- **Screen sharing quality** (Settings, kept on each device):
  - **Resolution:** 720p, 1080p (the default), 1440p, or as the screen is,
    counted on the screen's shorter side.
  - **Frame rate:** 5, 15 (the default), 30 or 60 frames a second. Phones
    stop at 30: Android captures its screen no faster.
  - **When it applies:** from the next share.
  - **Maximum bitrate:** automatic (the default), or 1, 2.5, 5, 8, 12, 20 or
    30 Mbit/s, whatever the resolution and frame rate: less for a slow upload,
    more to keep motion sharp. WebRTC still sends less while the network can't
    keep up.
  - **Upload, automatic:** about 0.08 bits a pixel each frame, from 0.3 to 12
    Mbit/s. That is 2.5 Mbit/s for 1080p at 15, and 8.8 for 1440p at 30.
  - **How:** LiveKit sizes a screen's encoding from a preset, not from the
    screen. So once the first frames tell its real size, the app has the
    encoder scale it down to the chosen height, at the chosen frame rate and
    the bitrate for that size (or the one chosen).
  - **When the network can't keep up:** at 30 frames a second or more, motion
    keeps going at a smaller size. Below 30, the picture stays sharp for text
    and comes less often.
- **Encryption:** video takes the same keys as the audio. A device's video goes
  out only once its key is set, and video that comes unencrypted is never
  shown.

The server lets the apps publish their microphone, camera and shared screen
with its sound, and says it has video in `GET /integrations` (`"video":
true`); apps on an older server show voice calls only. Whether a shared screen
may have sound, the apps learn from LiveKit (the server's grant): on an older
server they share without it.

## Setting it up

The Hanashi server needs four settings:

| Variable                     | Meaning                                                                            |
| ---------------------------- | ---------------------------------------------------------------------------------- |
| `HANASHI_LIVEKIT_URL`        | Where apps reach LiveKit: `wss://calls.example.org`, or `ws://` on a local network |
| `HANASHI_LIVEKIT_API_URL`    | Where the server reaches LiveKit's API; the same host over `http(s)://` unless set |
| `HANASHI_LIVEKIT_API_KEY`    | The key name LiveKit knows the server by                                           |
| `HANASHI_LIVEKIT_API_SECRET` | The secret shared with LiveKit: 32 or more random characters                       |

All of them, or none (no calls). LiveKit needs the same key and secret, and its
webhook pointed at the server's `/livekit/webhook`. The sample
[`livekit.yaml`](../livekit.yaml) has both.

### On one machine or a local network

`docker compose --profile calls up` starts LiveKit beside the server with
`livekit.yaml`. Then:

1. In `livekit.yaml`, set `rtc.node_ip` to your machine's address on the
   network, so that phones there can reach it.
2. In `docker-compose.yml`, set the `HANASHI_LIVEKIT_*` settings.
   `HANASHI_LIVEKIT_URL` is `ws://<that address>:7880`, and
   `HANASHI_LIVEKIT_API_URL` is `http://livekit:7880`.
3. Open TCP 7880 and 7881, and UDP 7882, on the machine's firewall.

To run LiveKit by itself instead (the server outside Docker):

```
docker run --rm --network host -v $PWD/livekit.yaml:/etc/livekit.yaml:ro \
  livekit/livekit-server:v1.13.11 --config /etc/livekit.yaml
```

Then use the webhook URL `http://127.0.0.1:8080/livekit/webhook` in
`livekit.yaml`, and `HANASHI_LIVEKIT_URL=ws://<your address>:7880` for the server.

### On the internet

- Put LiveKit's port 7880 behind a reverse proxy with TLS (`wss://`), like the
  Hanashi server. The proxy must pass WebSocket upgrades on; with nginx:

  ```nginx
  location / {
      proxy_pass http://127.0.0.1:7880;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host $host;
      proxy_read_timeout 1h;
  }
  ```

- Open TCP 7881 and UDP 7882, and set `rtc.use_external_ip: true` (or
  `node_ip` to the public address). The audio goes to that address directly,
  never through the proxy.
- **With Cloudflare:** keep LiveKit's name "DNS only". The free certificate of
  Cloudflare's proxy covers `example.org` and `*.example.org`, but not a name
  two levels down such as `calls.chat.example.org`: TLS to it fails at
  Cloudflare. Proxying would hide nothing anyway, since every device in a call
  learns LiveKit's address.
- For networks that block UDP, LiveKit has a TURN server of its own (`turn:` in
  its config).

[LiveKit's documentation](https://docs.livekit.io) covers deploying it in
more detail.

### Checking it

Best from outside your network (DNS and routing can differ inside it):

- `curl https://calls.example.org/` answers `OK`.
- A WebSocket upgrade to `/rtc` without a token gets 401 (`no permissions to
access the room`). A 404 means the proxy drops the upgrade.

  ```sh
  curl -i --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==' \
    https://calls.example.org/rtc
  ```

When a call cannot start, the app says why, and Settings -> View log has the
details:

| The app says                         | Look at                                                     |
| ------------------------------------ | ----------------------------------------------------------- |
| Could not reach the call server      | `HANASHI_LIVEKIT_URL`, DNS, TLS, the proxy, LiveKit running |
| The call server turned the call away | The key and secret: the server's must be LiveKit's          |
| Could not connect the call's audio   | TCP 7881 and UDP 7882 reaching LiveKit's advertised address |
| The call could not start             | Nobody got into the room in 30 s; the log tells what failed |

The server's tests include one against a real LiveKit:
`HANASHI_TEST_LIVEKIT=1 go test ./internal/livekit/` starts LiveKit in Docker and
checks that it takes the server's tokens and that the server takes its
webhooks.

## The apps

- **Microphone permission:** the microphone is opened, and asked for, before
  a call starts, so nobody is rung for a call the device cannot speak in.
  macOS has the microphone entitlement; iOS and macOS say what it is for.
- **Starting a call asks first:** the call buttons in a chat's title bar ask
  before a call goes out, or before joining one going on, so a click that
  missed calls nobody.
- **Mute and deafen:** deafen plays nobody's audio. The others see both, on
  the person's picture in the call bar and by their name in the video.
- **How loud each one plays here:** from silent to four times as loud (400%),
  in steps of 10%, a person's voice and their shared screen's sound each on
  its own slider. A tap on the pictures in the call bar sets everyone's; in
  the video, someone's tile has a button for it under the pointer, and a right
  click or a long press opens it too. Kept on the device, per person (all of
  their devices), for later calls as well. WebRTC turns the audio up after
  decoding it (it takes up to ten times), so sound that is already loud
  clips; on phones, a shared screen's sound has it applied where it plays as
  media (`StreamSound.kt`).
- **The voice goes out only while someone speaks** (Linux and Android): after
  WebRTC's echo cancelling and noise suppression, a voice gate lets the
  microphone's audio out once it is louder than a threshold. In between it
  sends silence, which Opus sends as next to nothing. A shared screen's sound
  never goes through it.
  - **The threshold:** by itself, 15 dB over the quietest the last 2 seconds
    were (the noise around), between -55 and -30 dBFS; or one set in Settings
    -> Voice. A meter there shows the microphone's level, green while it goes
    out: during a call, or while "Test your microphone" runs (its audio goes
    nowhere).
  - **Opening and closing:** it opens after 30 ms at the threshold, so a short
    click does not open it, and lets out the 30 ms before too (the audio is
    held back that long), so a word's first sound is not cut. It stays open
    while the level stays within 4 dB of the threshold, and for 400 ms after;
    after a burst under 100 ms (a loud click), for only 100 ms. It fades in and
    out over 10 ms.
  - **Measured** (Linux and an Android emulator, speech over steady noise,
    through LiveKit): sentences open it within 0.1 s; a closed gate sends about
    0.4 kB/s against 7 kB/s open; the others are told within 10 to 30 ms.
  - **Who speaks:** the green ring shows while someone's gate lets their voice
    out. Each device tells the others as its gate opens and closes, in a
    LiveKit data message encrypted with the call's key (see
    [protocol.md](protocol.md#calls)). Devices without a gate (Windows, macOS,
    iPhones), and calls where LiveKit lets no data messages through, get
    LiveKit's own guess from the audio levels instead. So does a device
    whose WebRTC stops handing its gate the microphone's audio: the app
    notices within seconds, and says so in its log.
  - The gate's code is `app/linux/webrtc/voice_gate_core.h` and its twin in
    `VoiceGate.kt`.
- **Push to talk** (Settings -> Voice, where the gate is): the voice goes out
  only while something is held, from that moment, and for 200 ms after it is
  let go (the end of the last word). The green ring shows meanwhile, as above.
  - **The talk button** in the call's controls, held down: on phones the way
    to talk, on the desktop one more.
  - **A key while Hanashi is in front** (desktop): chosen in Settings by
    pressing it. It still types where it types, so one you don't type with
    (F13, Scroll Lock, Pause) works best.
  - **A key in every app** (Linux): kept by the desktop itself, through the
    desktop portal's global shortcuts (KDE Plasma, GNOME). Settings sets it up
    once: the desktop asks which key, offering the one chosen in Hanashi, and
    files it under Hanashi's app ID. During calls the desktop tells Hanashi
    while it is held; Hanashi keeps no session with it between calls, so the
    key is the desktop's to give elsewhere then. A desktop knows the app ID
    only from an installed desktop file (the packages install
    `app.nullpointr.hanashi.desktop`); without one there is no key in every
    app, and Settings says so, rather than a key filed under whatever ran
    Hanashi (a terminal, an editor), or asked for at every call.
- **Linux:** WebRTC goes through PulseAudio, which PipeWire provides.
- **While a call rings or goes on,** the app stays connected to the server
  even in the background on phones, so the call's keys keep up with the
  group.

### Android

- **In the background:** while the phone is in a call, a notification
  ("Voice call" or "Video call", with Hang up) keeps the app running and its
  microphone open (a foreground service). Back on the app's first screen sends
  it to the background, as Android does since version 12; swiping it away from
  the recent apps ends the call.
- **Earpiece or speaker:** a chat of two starts on the earpiece, a group or a
  video call on the speaker; a headset goes first. With the earpiece, the
  screen goes dark against the ear.
- **The camera** pauses while the app is in the background (Android gives no
  camera to apps there), and comes back with the app. The others see the
  camera off meanwhile.
- **Sharing the screen:** Android asks each time, for one app or the entire
  screen. Then the call's notification also stands for capturing the screen
  (Android wants a foreground service of type `mediaProjection` for that,
  started after the user agrees), and goes back to the microphone alone once
  sharing stops. The system's own "Stop sharing" (the chip in the status bar)
  stops it in the app too: flutter_webrtc does not tell, so the app watches the
  display it shares through, which goes dark while the screen itself is on.
- **Ringing:** the server pushes a `call` when a chat of two rings someone, and
  a `call_stop` when it stops (see [protocol.md](protocol.md#calls)). The
  phone rings with its own ringtone, keeping to its silent and vibrate modes:
  from the app while the app is in front, and otherwise from a notification
  with Accept and Decline, also while the app is closed. Decline works
  without opening the app. A call that stops unanswered leaves a "Missed voice
  call" notification. Names in these notifications follow "Show sender and
  message".
- **On the lock screen:** a call that rings while the phone is locked shows
  full screen, over the lock screen. The app shows that call and nothing else
  there; "Unlock to open Hanashi" leads to the rest. Once the call is over,
  the lock screen is back. A call with video shows its video there as in the
  app, with names and pictures only if notifications show them.
- **Full-screen calls are a permission:** Android 14 lets the user turn them
  off for an app (and Google Play does for apps that are not for calling).
  Without it, calls ring as a heads-up notification only, and Settings ->
  Notifications says so, with a way to allow it.

## Later

- Sharing the screen from iPhones (a broadcast extension); a shared screen's
  sound on Android (its playback capture), Windows and macOS, and in stereo.
- Keys per sender.
- Calls across servers. The chat's hub server hosts the call in its LiveKit;
  members of other servers get their tokens through their own server, which
  asks the hub, as it does for commit leases.
- iOS: CallKit and VoIP pushes.
- Choosing microphone and speaker.
