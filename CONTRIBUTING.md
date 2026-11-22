# Contributing

Thank you for helping. Bug reports, ideas and pull requests are all welcome.

- **A security problem:** please do not open an issue; see
  [SECURITY.md](SECURITY.md).
- **A bug or an idea:** open an issue. For a bug, say which versions of the
  app and the server (Settings → About shows both), and on which platform.

## Making a change

The [README](README.md) says how to run the server and the app, and how to
run the tests. For a large change, open an issue first, to agree on the way.

- Keep a pull request to one change, and say why it is wanted.
- Add or change tests along with the code. Before opening the pull request,
  run the checks of what you touched, as CI does:

  ```sh
  (cd server && gofmt -l . && go vet ./... && go test ./...)
  (cd protocol && dart analyze --fatal-infos && dart test)
  (cd app && dart analyze --fatal-infos && flutter test)
  ```

- Format Go with `gofmt` and Dart with `dart format` (120 columns, set in
  each package's `analysis_options.yaml`); CI checks both. Generated code
  (`*.g.dart`) is left as its generator writes it.
- Screenshot tests compare against images in `app/test/goldens/`. If your
  change is meant to change how something looks, update them with
  `flutter test --update-goldens` and look at the new images.
- A change to what apps and servers send each other goes into
  [docs/protocol.md](docs/protocol.md) too. Apps and servers of the same
  release must keep working with each other (see "Client levels" there).
- Add a line for it under "Unreleased" in [CHANGELOG.md](CHANGELOG.md),
  written for the people using the app or running a server.

The app bundles only its own pictures, sounds and names, none from games or
other works (see the note in the README). Themes and sticker packs are
imported by their users, never bundled; `app/test/app_files_test.dart` checks
what the app bundles.

## License

Hanashi is under the GNU Affero General Public License, version 3
([LICENSE](LICENSE)). By contributing, you agree that your contribution is
under that license too.
