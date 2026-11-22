# Hanashi server

The server of [Hanashi](https://github.com/N1kO23/Hanashi), a self-hosted chat
app: direct and group chats, files, voice and video calls, and one account on
many devices. Messages and files are end-to-end encrypted with MLS: the server
only stores and passes on ciphertext.

The apps, for Android, iOS, Linux, Windows and macOS, are on the
[releases page](https://github.com/N1kO23/Hanashi/releases).

## Tags

- `latest`: the newest release.
- `1.0.5` and so on: one per release. Pin one, and upgrade when you choose to.

Each is built for `linux/amd64` and `linux/arm64` (a Raspberry Pi or an ARM
server, say).

## Quick start

The server needs MariaDB. This `compose.yaml` runs both:

```yaml
services:
  mariadb:
    image: mariadb:11.8
    environment:
      MARIADB_DATABASE: hanashi
      MARIADB_USER: hanashi
      MARIADB_PASSWORD: change-me # here and in HANASHI_DB_DSN below
      MARIADB_RANDOM_ROOT_PASSWORD: "1"
    volumes:
      - hanashi-database:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 20
    restart: unless-stopped

  hanashi:
    image: n1ko23/hanashi-server:1.0.5
    depends_on:
      mariadb:
        condition: service_healthy
    ports:
      - "8080:8080"
    environment:
      HANASHI_DB_DSN: hanashi:change-me@tcp(mariadb:3306)/hanashi
      # User IDs are name@HANASHI_HOST, for good: set your domain before the
      # first account signs up.
      HANASHI_HOST: chat.example.org
    volumes:
      - hanashi-media:/data
    restart: unless-stopped

volumes:
  hanashi-database:
  hanashi-media:
```

```sh
docker compose up -d
```

Then sign up in the app with the server's address: `http://<this machine>:8080`
on your own network. Anywhere else, put the server behind a reverse proxy with
TLS (Caddy or nginx, say) and use its `https://` address in the apps.

With a MariaDB you already have:

```sh
docker run -d --name hanashi -p 8080:8080 -v hanashi-media:/data \
  -e HANASHI_DB_DSN='hanashi:secret@tcp(db.example.org:3306)/hanashi' \
  -e HANASHI_HOST=chat.example.org \
  n1ko23/hanashi-server:1.0.5
```

## Settings

Settings are environment variables. The main ones:

| Variable                | Default              | Meaning                                                                                                       |
| ----------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------- |
| `HANASHI_DB_DSN`        | required             | MariaDB DSN, e.g. `user:pass@tcp(host:3306)/hanashi`                                                          |
| `HANASHI_DB_CREATE`     | `false`              | Create the database if it does not exist                                                                      |
| `HANASHI_HOST`          | `localhost`          | Public host name; user IDs are `name@HANASHI_HOST`. Set it before the first account: accounts stay tied to it |
| `HANASHI_REGISTRATION`  | `open`               | `open`, `invite` or `closed`                                                                                  |
| `HANASHI_INVITE_CODES`  |                      | Comma-separated codes for `invite`                                                                            |
| `HANASHI_MAX_UPLOAD_MB` | `100`                | Largest file accepted                                                                                         |
| `HANASHI_KLIPY_API_KEY` |                      | Turns on GIF search, with a [KLIPY](https://klipy.com/developers) key                                         |
| `HANASHI_LIVEKIT_URL`   |                      | Turns on voice and video calls through [LiveKit](https://github.com/N1kO23/Hanashi/blob/main/docs/calls.md)   |
| `HANASHI_FEDERATION`    | `off`                | `on` lets your users chat with those of other servers you list                                                |
| `HANASHI_SOURCE_URL`    | Hanashi's repository | Where your server's source code is, shown in the apps (see License)                                           |
| `HANASHI_LOG_LEVEL`     | `info`               | `debug`, `info`, `warn` or `error`                                                                            |

All of them, and how calls and federation are set up, are in the
[README](https://github.com/N1kO23/Hanashi#running-the-server).

## The image

- Listens on port `8080`.
- Keeps uploaded files, encrypted, in `/data`: keep it in a volume, and back
  it up with the database.
- Runs as user and group `10001`, not as root. A folder bind-mounted at
  `/data` must be writable by it: `sudo chown 10001:10001 ./data`.
- Run one server per database.

## Upgrading

Change the tag in your compose file (or pull `latest`), then:

```sh
docker compose pull && docker compose up -d
```

The server updates its database itself when it starts.

## License

Hanashi is free software under the
[GNU Affero General Public License, version 3](https://github.com/N1kO23/Hanashi/blob/main/LICENSE),
with no warranty. If you run a changed server for others, the license asks you
to offer them its source: publish it and set `HANASHI_SOURCE_URL` to where it
is. The apps show your users that link.
