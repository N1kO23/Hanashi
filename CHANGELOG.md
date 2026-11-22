# Changelog

What changed in each release, the newest first. Apps and servers of every
1.0 release work with each other; a server needs updating only where a
release says so. Each release's notes on GitHub are its section here.

## [Unreleased]

### Fixed

- When the server a group runs on could not be reached, your messages to
  every other chat waited too, until the app reconnected. Now only that
  group's messages wait, and they go by themselves once its server is back.

### Added

- A chat whose server can't be reached says so, and names the server, while
  its messages wait. Servers name it in their answer from this release on;
  with an older server, the app says "the server this chat runs on".
- Across servers, a group goes on without the server it was started on: once
  none of that server's users are in it, the server hands the group to the
  server with the most of its other members, which runs it from then on.
  Nothing changes for the people in it, and their apps need no update. It
  moves only if the servers of all its members run this release or later.
- `HANASHI_HAND_OVER=all` hands over every chat and group with members on
  other servers, for shutting a server down without ending its users' chats
  with others (see the README).

### Changed

- Servers upgrade their database when they start: the event log gets a new
  index, which takes a moment on a large one.

## [1.0.5] - 2026-11-22

### Changed

- Sticker packs you keep are stored encrypted on the device, as received
  media are since 1.0.3. After updating, each pack you kept is downloaded
  once more, and its unencrypted copy deleted.

## [1.0.4] - 2026-11-22

### Changed

- Photos, thumbnails and profile pictures shown again (scrolling back up a
  chat, opening a photo twice) are not decrypted again: what was decrypted
  lately stays in memory, up to 48 MB.
- The server image is based on Alpine 3.24, with updated Go dependencies
  (the MySQL driver, `golang.org/x/crypto`). Updating the server is optional.

## [1.0.3] - 2026-11-22

### Security

- Received photos, videos and files are no longer kept decrypted on the
  device. The cache keeps them encrypted, as the server has them: photos are
  decrypted into memory to show them, videos and audio as they play. On its
  first start, the app deletes the decrypted copies earlier versions kept;
  anything still on the server is downloaded again when opened.
- The thumbnail made for a photo or video you send is no longer left behind,
  unencrypted, in the app's temporary folder.

## [1.0.2] - 2026-11-22

### Security

- A malicious server, or a contact who knew a group you are in, could
  replace that group's encryption state on your device with a group of their
  own ([GHSA-c4gr-cfx2-h3wx](https://github.com/N1kO23/Hanashi/security/advisories/GHSA-c4gr-cfx2-h3wx)).
  Fixed by openmls 4.0, and by the app accepting a Welcome only for the
  conversation it was delivered for. Update the app on every device; servers
  need no update.

### Fixed

- Linux: the app quits when the desktop asks it to, at logout or shutdown.
  Where no sound server answered, the video player's sound library kept the
  signal to itself.

### Changed

- Updated dependencies, among them flutter_local_notifications 23 (Android
  builds now use SDK 37).

## [1.0.1] - 2026-11-22

### Fixed

- A message that went out just as the app signed out or shut down could fail
  to be marked as sent: the database closed under it.

### Added

- `docker-compose.yml` runs the published server image,
  [`n1ko23/hanashi-server`](https://hub.docker.com/r/n1ko23/hanashi-server)
  (amd64 and arm64); `docker compose up --build` still builds it from source.

## [1.0.0] - 2026-11-21

The first release under the Hanashi name, and as open source, under the
GNU Affero General Public License, version 3. It starts afresh: nothing
carries over from versions before 0.9 (see
[Coming from 0.8 or earlier](https://github.com/N1kO23/Hanashi#coming-from-08-or-earlier)).

### Added

- Settings → About: the app's version, its license and source code, the
  licenses of what it is made with, and your server's version and source.
- Servers say where their source code is (`HANASHI_SOURCE_URL`), as the AGPL
  asks of a server run for others.

[Unreleased]: https://github.com/N1kO23/Hanashi/compare/v1.0.5...HEAD
[1.0.5]: https://github.com/N1kO23/Hanashi/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/N1kO23/Hanashi/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/N1kO23/Hanashi/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/N1kO23/Hanashi/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/N1kO23/Hanashi/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/N1kO23/Hanashi/releases/tag/v1.0.0
