# Security

Hanashi is an end-to-end encrypted chat app, so a flaw in its security matters
more than most bugs. Thank you for looking.

## Reporting a vulnerability

Please do not open a public issue. Report it privately through GitHub instead:
the repository's **Security** tab, then **Report a vulnerability**
([straight there](https://github.com/N1kO23/Hanashi/security/advisories/new)).
Only you and the maintainers see the report.

It helps to include:

- what the problem is, and what someone gains by it (reading messages,
  pretending to be someone, taking a server down...);
- which versions it affects (the app, the server, or both) and on which
  platforms;
- how to reproduce it: steps, or a proof of concept.

Reports are answered as soon as possible. The fix comes in a new release, and
the advisory is published once that is out, crediting you unless you would
rather not be named.

## What counts

The apps, the server, the protocol between them, the Docker image and the
release packages. The [threat model](docs/protocol.md#threat-model) says what
the encryption protects and what it does not: for example, the server sees who
talks to whom and when. A way around what it promises is a vulnerability. What
it says is not hidden is not, though ideas for hiding more are welcome as
ordinary issues. Neither are the gaps the README already lists under
[Not done yet](README.md#not-done-yet).

## Supported versions

Only the latest release gets security fixes, so keep the apps and the server
up to date. The server tells apps too old for it to update.
