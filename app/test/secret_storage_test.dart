import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/app.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/e2ee/secure_store.dart';
import 'package:hanashi/main.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/encryption/encryption_screens.dart';

import 'support/test_app.dart';

/// A file store without the file system.
class _MemoryFile extends FileSecureStore {
  _MemoryFile(super.dir);

  var created = false;

  @override
  Future<bool> exists() async => created;

  @override
  Future<void> create() async => created = true;
}

/// The system keyring, missing.
class _NoKeyring extends PlatformSecureStore {
  @override
  Future<bool> isAvailable() async => false;
}

/// A keyring that is gone until [works] is set.
class _FlakyStore extends MemorySecureStore {
  var works = false;

  @override
  Future<String?> read(String key) async {
    if (!works) throw PlatformException(code: 'Libsecret error', message: 'No keyring is running');
    return super.read(key);
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('hanashi_secrets_'));
  tearDown(() => dir.delete(recursive: true));

  test('the file store keeps its secrets across starts, readable only by the user', () async {
    final store = FileSecureStore(dir);
    expect(await store.exists(), isFalse);
    await store.create();
    await store.write('account', '{"token":"t"}');
    await store.write('identity.seed', 's');
    await store.write('other', 'o');
    await store.deleteAll(prefix: 'identity.');

    final again = FileSecureStore(dir);
    expect(await again.exists(), isTrue);
    expect(await again.read('account'), '{"token":"t"}');
    expect(await again.read('identity.seed'), isNull);
    if (!Platform.isWindows) {
      final mode = (await again.file.stat()).mode & 0x1ff;
      expect(mode.toRadixString(8), '600');
    }
  });

  test('keys move from the file into a keyring that became available', () async {
    final file = FileSecureStore(dir);
    await file.create();
    final store = SwitchableSecureStore(file)..write('account', 'a');
    await store.write('device.key', 'k');
    final keyring = MemorySecureStore();
    await store.moveTo(keyring);
    expect(keyring.values, {'account': 'a', 'device.key': 'k'});
    expect(await file.exists(), isFalse);
    await store.write('later', 'l'); // Goes to the keyring now.
    expect((keyring.values['later'], await file.exists()), ('l', false));
  });

  testWidgets('without a keyring: try again, or keep the keys in a file', (tester) async {
    var keyring = false;
    var usedFile = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: KeyringMissingScreen(onRetry: () async => keyring, onUseFile: () async => usedFile = true),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('keyring-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Still no keyring.'), findsOneWidget);
    keyring = true;
    await tester.tap(find.byKey(const Key('keyring-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Still no keyring.'), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('keyring-use-file')));
    await tester.tap(find.byKey(const Key('keyring-use-file')));
    await tester.pumpAndSettle();
    expect(usedFile, isTrue);
  });

  testWidgets('a store that fails says so, instead of loading forever', (tester) async {
    await setSurfaceSize(tester, const Size(1000, 800));
    final store = _FlakyStore();
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [secureStoreProvider.overrideWithValue(store), databaseProvider.overrideWithValue(db)],
        child: const HanashiApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text("Cannot read this device's keys"), findsOneWidget);
    expect(find.text('No keyring is running'), findsOneWidget);

    store.works = true;
    await tester.tap(find.byKey(const Key('unavailable-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
  });

  testWidgets('a start without a keyring: the choice of a file, then the app in its place', (tester) async {
    final file = _MemoryFile(dir);
    Widget? shown;
    SecureStore? result;
    unawaited(
      chooseSecretStore(dir, keyring: _NoKeyring(), file: file, show: (app) => shown = app).then((s) => result = s),
    );
    await tester.pump();
    await tester.pumpWidget(shown!);
    await tester.ensureVisible(find.byKey(const Key('keyring-use-file')));
    await tester.tap(find.byKey(const Key('keyring-use-file')));
    await tester.pump();
    expect((result, file.created), (file, true));

    // The app's own scope replaces the screen's, as in main().
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [secureStoreProvider.overrideWithValue(MemorySecureStore()), databaseProvider.overrideWithValue(db)],
        child: const HanashiApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
    // The next start remembers the choice.
    expect(await chooseSecretStore(dir, keyring: _NoKeyring(), file: file, show: (_) => fail('asked again')), file);
  });
}
