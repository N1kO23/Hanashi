# Hanashi

[![CI](https://github.com/N1kO23/Hanashi/actions/workflows/ci.yml/badge.svg)](https://github.com/N1kO23/Hanashi/actions/workflows/ci.yml)

A self-hostable chat app with a UI inspired by the messenger in _Blue
Archive_. The app is Flutter (Android, iOS, Linux, Windows and macOS); the
server is Go with MariaDB. 0.9 started afresh under a new name (see
[Coming from 0.8 or earlier](#coming-from-08-or-earlier)).

- Text, photos, videos (WebM too) and any other files; audio files play in
  the app. On a computer, drop files onto
  a chat or paste them (or a copied image or screenshot) with Ctrl+V;
  the app asks before sending.
- Replies, reactions (six quick ones or any emoji), and editing or deleting
  your own messages for everyone: long-press a message, right-click it, or
  use the buttons that appear when the mouse is over it. The emoji button
  next to the input opens a full emoji picker.
- GIFs: search KLIPY (if the server has a KLIPY key) or send one you saved.
  Save any GIF from a chat with a long press; saved GIFs follow you to your
  other devices, end-to-end encrypted. GIF files play in chats too.
- Stickers, under the emoji button: they show large, without a bubble.
  Sticker packs come with the stickers people send you: tap one to add its
  pack, or import a pack's file in the sticker tab (see
  [Making a sticker pack](#making-a-sticker-pack)). A sticker goes as its
  picture, so everyone sees it, pack or not. The app comes with none. Make
  stickers of your own from any image with the "+" under "My stickers", or keep one you
  like: long-press it in a chat or in the sticker tab. Your packs and stickers
  follow you to your other devices, end-to-end encrypted, and a picture is
  uploaded once, not with every message.
- Custom emojis: make your own from an image, then write `:its_name:` in any
  chat; a group can have emojis of its own, which anyone in it can add. Type
  `:` and a few letters for suggestions, standard emoji included. A message
  carries the pictures it uses, so it looks the same to everyone, and tapping
  one lets you add it to yours.
- Voice and video calls, if the server has a [LiveKit](docs/calls.md) beside
  it: a chat of two rings, a group has a call anyone in it can drop into, and
  anyone in a call can turn their camera on or share their screen. The audio
  and video are end-to-end encrypted with keys from the chat's group. On
  Android a call rings like a phone call, also while the app is closed and over
  the lock screen.
- Links open in the browser. Before you send one, your app makes a preview
  (title, picture, and any video or GIF the page shows), which goes along
  encrypted: the people you send it to don't contact the website. A link
  straight to an image or file can be sent as the file itself. Previews can be
  turned off in Settings. A video or GIF too large to go along can be loaded
  from the website in the viewer, if you turn that on in Settings; you're
  asked each time.
- Notifications for new messages, replies to you and reactions to your
  messages, and for contact requests and answers to yours, with the theme's
  sound. Settings choose which of these notify
  on each device, and whether with a sound. Each chat has a menu (⋮ in the
  chat, or a long press or right click on it in the list) to mark it read,
  mute it for a while or until you unmute it, and open its settings; there
  it can also notify only about replies and reactions to you, or be silent.
  Chat settings follow you to your other devices, end-to-end encrypted. Muted chats keep a grey unread count. In Focus,
  notifications wait and show silently once Focus ends.
- Profiles like the game's: picture, name, a status message and your
  birthday (month and day), changed in Settings and shown when you tap
  someone's picture. All but the name are end-to-end encrypted: only you and
  people you chat with can see them. Groups have pictures too (in the
  group's info), encrypted for its members.
- A status on everyone's picture: online, idle (after a few minutes away),
  in focus, or offline. In Settings you can pick Focus, or appear offline
  with Invisible.
- Contacts: add someone by their user ID, and they become a contact once they
  accept; until then, nothing but your user ID reaches them, and only contacts
  can message you or add you to a group. You can decline, remove or block, and
  whoever you turn down is not told. Contacts are listed as the game lists
  students: today's and upcoming birthdays first, then everyone with their
  status message and status, sorted by name, status or birthday. Tapping one
  shows their profile: beside the list on a computer, in its place on a phone.
- End-to-end encrypted with MLS: the server stores only ciphertext, files
  included. Each device has its own keys; a new device is verified by
  comparing emoji with one of your other devices (or with the account's
  recovery key) and reads your history from an encrypted key backup.
  Compare emoji with a contact to verify them too: if their security key
  ever changes, Hanashi holds your messages to them until you check again.
  Names, profiles and group titles and pictures are end-to-end encrypted too,
  and reach someone new at once, without any of the chat's messages. On the
  device, the database is encrypted, and media stay as the server has them:
  photos are decrypted into memory to show them, videos and audio as they
  play, and nothing to the disk but a file you save.
- Direct chats and group chats: start a group from Contacts, add people,
  rename it or leave from the group's info. Any member can do these; there
  are no group admins. Whoever adds someone can share the chat history with
  them (ticked by default), so they can read what was said before they
  joined. Typing indicators show who is writing
  (Settings -> Privacy turns off showing your own, per device).
- One account on many devices: chats, new conversations and read state stay
  in sync between your phone and your desktop.
- Chat text sized for each screen: Settings set the text size, line spacing and
  bubble padding on each device, with a sample chat that follows along.
- Light and dark mode, or as the system is, and themes: a theme brings its
  colours for both, and may bring a title-bar logo, an icon, its own sounds
  and a name for the app, which it then goes by in its title bar, its window,
  the tray and its notifications. Choose them in Settings, under Appearance,
  and import a theme's file there (see [Making a theme](#making-a-theme)).
  The app comes with seven: Default's teal, Sakura (the pink it had before
  0.9), Ocean, Forest, Lavender, Ember and Graphite. On Android, "Add to home
  screen" there pins a shortcut with the theme's icon and name, which follows
  the theme. Themes and the choice belong to the device, and stay when you
  sign out.
- Messages go over a WebSocket. Messages sent while offline wait in an outbox
  and go out exactly once when the connection returns.
- Notifications. Android gets them while the app is closed, through
  [UnifiedPush](https://unifiedpush.org): a distributor app such as ntfy,
  or Google's push service on phones with Google Play (built in, nothing to
  set up). Pushes carry no content: the phone fetches and decrypts the
  message itself. On desktop, closing the window keeps Hanashi running in
  the tray.
- Received files are never opened automatically; they are saved for you to
  inspect.
- Self-hosting is one `docker compose up`. Servers can federate when their
  operators turn it on: their users then become contacts and chat with each
  other as on one server, groups included.

> This is a fan project, not affiliated with Nexon or Yostar. Neither the
> app nor this repository holds any of _Blue Archive_'s art or names, which
> belong to them.

## Coming from 0.8 or earlier

0.9 started afresh, under the app's new name and with encryption of its own;
nothing carries over from 0.8 or earlier, and those apps and servers cannot
talk to 0.9 or later.

- **Apps** install as a new app, beside the old one: sign in again and set
  up encryption anew (with a new recovery key). Uninstall the old app when
  you like; until then its data stays in its own folders.
- **Servers** need an empty database, and their users sign up again: a
  server of 0.9 or later does not start with an earlier version's database in
  use, and says so. With `docker-compose.yml`,
  `docker compose up -d --remove-orphans` starts afresh (its volumes have new
  names) and removes the old container; the old volumes stay until you
  `docker volume rm` them.
- **Server settings** are named `HANASHI_*` now, in place of `MOMO_*`. A server
  takes no notice of the old names, so rename them in your environment or
  compose file before starting it.
- A server tells an app too old for it to update (see
  [Client levels](docs/protocol.md#client-levels)).

## Repository layout

| Path                 | What                                                                |
| -------------------- | ------------------------------------------------------------------- |
| `server/`            | The Go server (MariaDB, REST + WebSocket)                           |
| `app/`               | The Flutter app                                                     |
| `protocol/`          | Dart wire-format package used by the app, plus shared test fixtures |
| `packaging/`         | Scripts that package the app for Linux, Android and Windows         |
| `docs/protocol.md`   | Protocol and API reference, federation included                     |
| `docs/federation.md` | Where federation and other networks stand, and what is left         |

## Running the server

With Docker (starts MariaDB too), from the released image,
[`n1ko23/hanashi-server`](https://hub.docker.com/r/n1ko23/hanashi-server)
(amd64 and arm64):

```sh
docker compose up -d
HANASHI_PUBLISH_PORT=9090 docker compose up -d   # if port 8080 is taken
docker compose up -d --build                     # this checkout's server, built from source
```

Change the database password in `docker-compose.yml` before exposing it.
The compose file names the image of its own version, so after a `git pull`,
`docker compose up -d` fetches the new one.

The image runs without Compose too, with a MariaDB of your own:

```sh
docker run -d --name hanashi -p 8080:8080 -v hanashi-media:/data \
  -e HANASHI_DB_DSN='hanashi:secret@tcp(db.example.org:3306)/hanashi' \
  -e HANASHI_HOST=chat.example.org \
  n1ko23/hanashi-server:1.0.4
```

From source (needs Go 1.26+ and a MariaDB database):

```sh
cd server
HANASHI_DB_DSN='hanashi:secret@tcp(localhost:3306)/hanashi' go run ./cmd/hanashi-server
```

Settings are environment variables:

| Variable                     | Default                     | Meaning                                                                                                                                             |
| ---------------------------- | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `HANASHI_DB_DSN`             | required                    | MariaDB DSN, e.g. `user:pass@tcp(host:3306)/hanashi`                                                                                                |
| `HANASHI_DB_CREATE`          | `false`                     | Create the database if it does not exist                                                                                                            |
| `HANASHI_HOST`               | `localhost`                 | Public host name; user IDs are `name@HANASHI_HOST`. Set it to your domain before the first account: accounts stay tied to it                        |
| `HANASHI_PORT`               | `8080`                      | Port to listen on                                                                                                                                   |
| `HANASHI_BIND`               | `0.0.0.0`                   | Address to bind                                                                                                                                     |
| `HANASHI_DATA_DIR`           | `data`                      | Uploaded media                                                                                                                                      |
| `HANASHI_REGISTRATION`       | `open`                      | `open`, `invite` or `closed`                                                                                                                        |
| `HANASHI_INVITE_CODES`       |                             | Comma-separated codes for `invite` mode                                                                                                             |
| `HANASHI_MAX_UPLOAD_MB`      | `100`                       | Largest accepted file                                                                                                                               |
| `HANASHI_MIN_CLIENT`         | `0`                         | Refuse apps below this [client level](docs/protocol.md#client-levels). Can only raise what the server itself needs, which refuses apps before 0.9.0 |
| `HANASHI_PUSH_CONTACT`       | `mailto:admin@HANASHI_HOST` | How push services can reach you (`mailto:` or `https:` URL)                                                                                         |
| `HANASHI_PUSH_ALLOW_PRIVATE` | `false`                     | Allow push endpoints on private networks (a self-hosted ntfy on your LAN)                                                                           |
| `HANASHI_KLIPY_API_KEY`      |                             | Turns on GIF search (see below)                                                                                                                     |
| `HANASHI_SOURCE_URL`         | Hanashi's repository        | Where your server's source code is, which the apps show its users. Running a changed server? Point it at your source (see [License](#license))      |
| `HANASHI_LIVEKIT_URL`        |                             | Turns on calls: where apps reach LiveKit (`wss://`, or `ws://` on a local network; see [Calls](docs/calls.md))                                      |
| `HANASHI_LIVEKIT_API_URL`    | from `HANASHI_LIVEKIT_URL`  | Where the server reaches LiveKit's API                                                                                                              |
| `HANASHI_LIVEKIT_API_KEY`    |                             | The key LiveKit knows the server by                                                                                                                 |
| `HANASHI_LIVEKIT_API_SECRET` |                             | The secret shared with LiveKit: 32 or more random characters                                                                                        |
| `HANASHI_LOG_LEVEL`          | `info`                      | `debug`, `info`, `warn` or `error` (see below)                                                                                                      |
| `HANASHI_FEDERATION`         | `off`                       | `on` lets your users and those of other servers become contacts (see below)                                                                         |
| `HANASHI_FEDERATION_SERVERS` |                             | Required with federation on: the servers to federate with, comma-separated, or `*` for any server                                                   |
| `HANASHI_FEDERATION_RESOLVE` |                             | `host=url,...`: where those hosts' servers answer, instead of looking it up (tests, private networks; the only way to use `http://`)                |
| `HANASHI_FEDERATION_RATE`    | `100`                       | Requests a second each other server may make (in bursts of ten seconds' worth; file fetches a tenth of it)                                          |

**Federation** (`HANASHI_FEDERATION=on`) lets your users and those of the servers
you list in `HANASHI_FEDERATION_SERVERS` find each other by ID, become contacts,
and chat in direct chats and groups (see [Federation](docs/protocol.md#federation)).
Both servers have to list each other. `HANASHI_FEDERATION_SERVERS=*` federates with
any server instead, which anyone could flood with servers of made-up names. A file sent from
another server is kept on yours once someone opens it. Other servers find yours
at `https://HANASHI_HOST`. If it runs at another address, serve that address from
your host's `/.well-known/hanashi/server` as `{"server": "https://chat.example.org"}`.

The server logs every request with the user and device that sent it, and the
error code of those that failed. With `HANASHI_LOG_LEVEL=debug` it also logs
each commit lease, commit, key change, Welcome, sync page and WebSocket
request, with conversation IDs and MLS epochs: what is needed to find out why
a device fell out of a chat. Logs never hold message contents, keys,
passwords or tokens (the server never sees the first two).

GIF search uses [KLIPY](https://klipy.com/developers): create a free API key
in KLIPY's partner panel and set it as `HANASHI_KLIPY_API_KEY`. Signed-in apps
get the key from the server and talk to KLIPY themselves; KLIPY's terms do
not allow requests or GIFs to go through your server. KLIPY therefore sees
the IP address of whoever searches or loads a GIF from it, but no account
name (users can turn off loading GIFs automatically in Settings). Leave ads
off for the key, as the app cannot show them, and block search terms or
content in KLIPY's partner panel if you need to.

Calls go through a [LiveKit](https://livekit.io) server beside this one:
`docker compose --profile calls up` starts one with [`livekit.yaml`](livekit.yaml).
[docs/calls.md](docs/calls.md) has the setup, and what the servers learn of calls
(not what is said or shown: the apps encrypt the audio and video).

Run one server process per database (see "Ordering guarantee" in
`docs/protocol.md`). For anything beyond a local network, put it behind a
reverse proxy with TLS (for example Caddy or nginx) and use `https://` in the app.

## Running the app

```sh
cd app
flutter pub get
flutter run -d linux                                    # or an Android device/emulator
flutter run -d linux --dart-define=HANASHI_DEMO=true   # sample chats, no server
```

On the login screen, enter the server address. From the Android emulator the
host machine is `http://10.0.2.2:8080`.

On desktop the app draws its own title bar: drag the pink bar to move the
window, double-click it to maximize, and use the buttons on its right to
minimize, maximize or close.

A chat's name at its top opens the other person's profile, or the group's
info.

Closing the window keeps Hanashi running in the tray, so messages and
notifications keep coming; quit from the tray icon's menu. Settings has
"Start when you log in" (Linux and Windows). Launching it again brings the
running copy back.

Building for Linux needs libmpv for video (`media-video/mpv` on Gentoo,
`libmpv-dev` on Debian/Ubuntu), the X11 and XInput libraries for the tray
icon and window controls (`x11-libs/libX11` and `x11-libs/libXi`,
`libx11-dev libxi-dev`) and
libsecret. The app keeps the encryption keys, the login token and the key
of its local database in the desktop's keyring (GNOME Keyring, KWallet, or
KeePassXC with Secret Service). Without one, it says so at start and offers
to keep them in a file only your user can read instead (not encrypted, so it
protects the database no better than the file's permissions do); Settings
moves them into a keyring later. The tray icon is a StatusNotifierItem, which KDE Plasma and most
other desktops show; GNOME does only with the AppIndicator extension.

The app keeps its data in the platform's app-data folder
(`~/.local/share/app.nullpointr.hanashi` on Linux). Its database, with
your messages, is encrypted (SQLite3MultipleCiphers), with a key kept in the
keyring. Received files are cached, decrypted, in the app's cache folder.

On Android, notifications while the app is closed come through a UnifiedPush
distributor: if the phone has one (for example
[ntfy](https://ntfy.sh), which you can self-host), Hanashi uses it;
otherwise it uses Google's push service through Play services. Settings
shows which one and lets you switch. A distributor on your own network
needs `HANASHI_PUSH_ALLOW_PRIVATE=true` on the server.

When you create an account, the app shows a recovery key once. Keep it safe:
signing in on another device needs it, and nobody can recover it for you.

### Making a sticker pack

A sticker pack is a zip file of `pack.json` and the stickers' pictures (see
[Sticker packs](docs/protocol.md#sticker-packs)). Make one from a folder of
pictures, then import it in the sticker tab ("Import pack file…"); from there
it travels with every sticker you send of it:

```sh
python3 app/tool/make_sticker_pack.py my-stickers/ --title "My stickers" --author "Me"
python3 app/tool/make_sticker_pack.py --check my-stickers.zip
```

Each picture becomes a sticker named after its file (`--number` numbers them
instead). WebP, PNG and GIF pictures that are stickers already (up to 512×512
and 512 KiB) go in as they are, needing nothing but Python; anything else is
fitted and made WebP, which needs Pillow (`python3 -m pip install pillow`).
The pack gets an ID of its own, printed when it is made: give it with `--id`
to make a new version of the same pack.

### Making a theme

A theme is a zip file of `pack.json` and the files it names (see
[docs/themes.md](docs/themes.md)): colours for light and dark mode, and if
you like, a logo and wordmark for the title bar, an icon for the tray, and
sounds for messages and calls. Put them in a folder, then pack it, which
checks it as the app does; it needs nothing but Python:

```sh
python3 app/tool/make_theme.py my-theme/
python3 app/tool/make_theme.py --check my-theme.zip
```

Import the file in Settings, under Appearance ("Import theme file…").

## Tests

Server tests and the app's integration tests need MariaDB. They use
`$HANASHI_TEST_DSN` (a DSN without a database, e.g. `root:pw@tcp(127.0.0.1:3306)/`)
if set; otherwise they start a throwaway Docker container named
`hanashi-test-mariadb` (data on tmpfs, port 33306) and leave it running for
the next run. Remove it with `docker rm -f hanashi-test-mariadb`.

```sh
(cd server && go test ./...)                          # API over real HTTP/WebSocket + MariaDB
(cd protocol && dart test)                            # envelope rules (shared fixtures with Go)
(cd app && flutter test)                              # widgets, goldens, sync against the Go server
(cd app && flutter test integration_test/app_e2e_test.dart -d linux)        # the real desktop app end to end
(cd app && flutter test integration_test/desktop_shell_test.dart -d linux)  # tray, close to tray, notifications
(cd app && flutter test integration_test/media_viewer_test.dart -d linux)   # photos, videos and audio in the viewer
```

Run desktop integration tests one file at a time: Flutter cannot start a
second test app on Linux within one `flutter test` run. CI runs all of these
(see [Builds and releases](#builds-and-releases)).

Push notifications through real FCM need an Android emulator or phone with
Google Play services and a server it can reach (start one on the host with
`HANASHI_PORT=18080`, then):

```sh
(cd app && flutter test integration_test/android_push_test.dart -d emulator-5554 \
  --dart-define=HANASHI_TEST_SERVER=http://10.0.2.2:18080)
adb shell pm grant app.nullpointr.hanashi android.permission.POST_NOTIFICATIONS   # once it is installed
```

## Builds and releases

GitHub Actions (`.github/workflows/ci.yml`) runs all the tests above (the
desktop ones under a virtual display) on every push to `main` and every pull
request. Screenshots that no longer match are uploaded as `golden-failures`.

Every push also builds every platform and the server's Docker image, as does
starting it by hand (**Run workflow** on the Actions page, or
`gh workflow run ci.yml --ref main`); a pull request builds only the image. The files are under the run's
**Artifacts** for 7 days. A version tag also publishes them as a GitHub
release once the tests pass (a tag with a suffix, like `v0.2.0-beta.1`,
becomes a pre-release):

```sh
git tag v0.2.0 && git push origin v0.2.0
```

Before tagging, give the release its version in `app/pubspec.yaml`, in the
server's `Version` (`server/internal/api/api.go`) and in the image
`docker-compose.yml` names; CI stops if the last two are not the tag's.
Runs without a tag check them against `app/pubspec.yaml`.

A tag also pushes the server's image to Docker Hub, for amd64 and arm64, as
`n1ko23/hanashi-server:<version>` and, unless it is a pre-release, `latest`
(other runs only build it). That needs a Docker Hub
[access token](https://app.docker.com/settings/personal-access-tokens) that
may read and write, as the repository secret `DOCKERHUB_TOKEN`:

```sh
gh secret set DOCKERHUB_TOKEN   # paste the token when asked
```

Without it, CI builds the image, pushes nothing and warns about it.

| Platform | Files                                                                   |
| -------- | ----------------------------------------------------------------------- |
| Android  | one `.apk` per CPU type (`arm64-v8a` for phones)                        |
| Linux    | `.AppImage` (any distribution), `.deb` (Debian, Ubuntu), or a `.tar.gz` |
| Windows  | `-setup.exe` installer (for you, or for everyone), or a `.zip`          |
| macOS    | `.dmg`, or a `.zip`                                                     |
| iOS      | unsigned `.ipa`                                                         |

A release also has `SHA256SUMS.txt`. Linux packages are built on Ubuntu 22.04
and run on distributions at least that new. They include libmpv and the
other libraries a desktop may lack; the system provides GTK 3, and VA-API
(videos decoded on the GPU) where it has it. Release
AppImages carry update information, so AppImage updaters (such as Gear Lever
or AppImageUpdate) find newer releases.

The same packages build on this machine, into `dist/`:

```sh
packaging/linux/build-appimage.sh   # .AppImage, .deb and .tar.gz, built in Docker
packaging/android/build-apks.sh     # one .apk per CPU type, signed with the release key (below)
```

The Linux packages are built in a Docker container of Ubuntu 22.04
(`packaging/linux/Dockerfile`), as in CI, so they run on the same
distributions as CI's, whatever this machine runs. `packaging/linux/package.sh`
does the packaging, for CI too; see the comment at its top.

Flutter builds Windows apps only on Windows. There, with Visual Studio's
"Desktop development with C++", Developer Mode on and Inno Setup 6
(`winget install JRSoftware.InnoSetup`), this builds the installer and the
`.zip` into `dist\`, as CI does (CI runs the same script):

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\build-installer.ps1
```

The macOS app is ad-hoc signed and not notarized; the iOS `.ipa` is
unsigned, for sideloading tools that sign it (AltStore, Sideloadly). The
Windows installer is unsigned, so SmartScreen warns before the first run.

Android updates only install over a version signed with the same key. Create
a release key once, keep a backup, and add it as repository secrets
(Settings -> Secrets and variables -> Actions):

```sh
keytool -genkeypair -keystore hanashi-release.jks -alias hanashi -keyalg RSA -keysize 4096 -validity 10000
base64 -w0 hanashi-release.jks    # the value for ANDROID_KEYSTORE_BASE64
```

| Secret                      | Value                                                                    |
| --------------------------- | ------------------------------------------------------------------------ |
| `ANDROID_KEYSTORE_BASE64`   | the keystore, base64-encoded                                             |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password                                                    |
| `ANDROID_KEY_ALIAS`         | `hanashi` (the `-alias` above)                                          |
| `ANDROID_KEY_PASSWORD`      | the keystore password again (keytool's default format uses one password) |

Or with the GitHub CLI, from the key's folder (the password in `password.txt`):

```sh
base64 -w0 hanashi-release.jks | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD < password.txt
gh secret set ANDROID_KEY_PASSWORD < password.txt
gh secret set ANDROID_KEY_ALIAS --body hanashi
```

Without them, CI signs with a throwaway key and warns about it.

Local builds, `flutter run` included, use the same key when
`app/android/key.properties` (kept out of git) points to it. Their version
code is the number of minutes since 2026-01-01 when they were built, as in
CI, so builds from CI and from this machine install over each other in the
order they were made, keeping the app's data:

```properties
storeFile=/path/to/hanashi-release.jks
storePassword=...
keyAlias=hanashi
keyPassword=...
```

## Not done yet

- iOS gets no push notifications (that needs Apple's push service and a
  developer account); it catches up when opened. Start at login is not
  available on macOS yet.
- Sticker packs you keep are stored unpacked on the device, not encrypted.
- Across servers, a chat or group cannot change while the server that orders
  it (its creator's, or for a direct chat the one sorting first) cannot be
  reached, and cannot move to another. Off-grid transports
  (Meshtastic/Reticulum) are far off. See [where these stand](docs/federation.md).

## Security

Please report vulnerabilities privately, not as issues: see
[SECURITY.md](SECURITY.md).

## License

Copyright © 2026 Niko Huuskonen.

Hanashi, the app and the server, is free software: you can redistribute it and
modify it under the terms of the GNU Affero General Public License, version 3
([LICENSE](LICENSE)). It comes with no warranty. If you run a modified server
for others, the license asks you to offer them its source: put it online and
set `HANASHI_SOURCE_URL` to where it is, and the apps show your users that link.

The emoji font the tests use is a subset of Noto Color Emoji, under the SIL
Open Font License ([app/test/fonts/OFL.txt](app/test/fonts/OFL.txt)).
