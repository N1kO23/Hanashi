// Runs the real app (real plugins, libmpv, SQLite, MLS) against the real Go
// server and MariaDB:  flutter test integration_test -d linux
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:hanashi/app.dart';
import 'package:hanashi/app_storage.dart';
import 'package:hanashi/data/account.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/data/models.dart';
import 'package:hanashi/data/remote/api_client.dart';
import 'package:hanashi/data/server_chat_repository.dart';
import 'package:hanashi/e2ee/encryption_identity.dart';
import 'package:hanashi/e2ee/sas.dart';
import 'package:hanashi/e2ee/verification_service.dart';
import 'package:hanashi/e2ee/secure_store.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/chat/chat_screen.dart';
import 'package:hanashi/ui/chat/message_bubble.dart';
import 'package:hanashi/ui/chat_list/chat_list_screen.dart';
import 'package:hanashi/ui/media/video_probe.dart';
import 'package:hanashi/ui/window/window_controls.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';
import 'package:openmls/openmls.dart';

import '../test/support/go_server.dart';

/// Pumps frames until [finder] finds something, or with [gone] nothing.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
  bool gone = false,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty != gone) return;
  }
  final visible = [
    for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? '',
  ].where((t) => t.isNotEmpty);
  throw TestFailure(
    'Timed out waiting for $finder${gone ? ' to go' : ''}. Visible text: ${visible.join(' | ')}',
  );
}

/// [text] as a message in the open chat says it, not as a chat list
/// preview or a reply's quote.
Finder said(String text) => find.byElementPredicate((e) {
  if (e.widget case Text(:final data) when data == text) {
    var inBubble = false, quoted = false;
    e.visitAncestorElements((a) {
      if (a.widget.key == const Key('reply-quote')) quoted = true;
      inBubble = a.widget is MessageBubble;
      return !inBubble;
    });
    return inBubble && !quoted;
  }
  return false;
});

/// Pumps frames until [probe] returns a value.
Future<T> pumpUntilValue<T extends Object>(
  WidgetTester tester,
  Future<T?> Function() probe, {
  required String reason,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    final value = await tester.runAsync(probe);
    if (value != null) return value;
    await tester.pump(const Duration(milliseconds: 100));
  }
  throw TestFailure('Timed out: $reason');
}

/// The other side of the conversation: a second account with its own
/// encryption identity, driven through the repository instead of a UI.
class _Contact {
  _Contact._(this.api, this.db, this.repo, this.verification);

  final ApiClient api;
  final AppDatabase db;
  final ServerChatRepository repo;
  final VerificationService verification;

  static Future<_Contact> signUp(String url, String name, Directory dir) async {
    final anonymous = ApiClient(url);
    final auth = await anonymous.register(
      name: name,
      password: 'password123',
      deviceName: 'bot',
      platform: 'test',
    );
    anonymous.close();
    final account = Account(
      serverUrl: url,
      userId: auth.userId,
      displayName: name,
      token: auth.token,
      deviceId: auth.deviceId,
    );
    final api = ApiClient(url, token: auth.token);
    final identity = EncryptionIdentity(
      api: api,
      account: account,
      store: MemorySecureStore(),
    );
    await identity.setUp();
    final db = AppDatabase(NativeDatabase.memory());
    late final ServerChatRepository repo;
    final verification = VerificationService(
      api: api,
      account: account,
      identity: identity,
      onUserVerified: (user, key) => repo.markVerified(user, key),
    );
    repo = ServerChatRepository(
      db: db,
      account: account,
      identity: identity,
      onSignedOut: () {},
      mediaDir: Directory('${dir.path}/media'),
      packsDir: Directory('${dir.path}/packs'),
      tempDir: Directory('${dir.path}/tmp'),
      onVerificationMessage: verification.handle,
    );
    repo.start();
    await repo
        .watchConnection()
        .firstWhere((s) => s == ConnectionStatus.online)
        .timeout(const Duration(seconds: 20));
    return _Contact._(api, db, repo, verification);
  }

  /// The conversation's messages, once they pass [test].
  Future<List<ChatMessage>?> messagesIf(
    String conv,
    bool Function(List<ChatMessage>) test,
  ) async {
    final messages = await repo.watchMessages(conv).first;
    return test(messages) ? messages : null;
  }

  Future<void> close() async {
    await repo.dispose();
    await db.close();
    api.close();
  }
}

bool _decrypted(List<ChatMessage> messages) => messages.every(
  (m) =>
      m.envelope.type != Envelope.encryptedType &&
      m.state == DeliveryState.sent,
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Render frames continuously like the real app; the video player's texture
  // setup waits for the engine and would stall under the pump-only default.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  MediaKit.ensureInitialized();
  // The app and Kumiko each have their own database.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(Openmls.init);

  testWidgets(
    'sign up, encrypted chat, attachments and devices in the real app',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('hanashi_e2e_');
      addTearDown(() => dir.delete(recursive: true));

      final server = (await tester.runAsync(GoServer.start))!;
      addTearDown(server.dispose);
      final url = server.url;

      // Kumiko, with encryption set up, is the other side of the conversation.
      final kumiko = (await tester.runAsync(
        () => _Contact.signUp(url, 'kumiko', Directory('${dir.path}/kumiko')),
      ))!;

      // The app's own database, encrypted as on a device: the library that
      // does it runs in this real app, beside the system's SQLite.
      final db = AppStorage.openDatabase(
        key: (await tester.runAsync(() => AppStorage.databaseKey(MemorySecureStore())))!,
        directory: Directory('${dir.path}/app')..createSync(),
      );
      final windowControls = await tester.runAsync(initDesktopWindow);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            // Never touch the real keychain from tests.
            secureStoreProvider.overrideWithValue(MemorySecureStore()),
            mediaDirProvider.overrideWithValue(Directory('${dir.path}/media')),
            videoProbeProvider.overrideWithValue(probeVideoWithPlayer),
            windowControlsProvider.overrideWithValue(windowControls),
          ],
          child: const HanashiApp(),
        ),
      );

      debugPrint(
        'E2E step 1: The in-app window buttons drive the real window.',
      );
      await pumpUntil(tester, find.byTooltip('Maximize'));
      await tester.tap(find.byTooltip('Maximize'));
      await pumpUntil(tester, find.byTooltip('Restore'));
      expect(appWindow!.isMaximized, isTrue);
      await tester.tap(find.byTooltip('Restore'));
      await pumpUntil(tester, find.byTooltip('Maximize'));
      expect(appWindow!.isMaximized, isFalse);

      debugPrint('E2E step 2: Create an account through the login screen.');
      await pumpUntil(tester, find.text('Create account'));
      await tester.tap(find.text('Create account').first);
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextFormField, 'Server'), url);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'User name'),
        'sota',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'password123',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Display name (optional)'),
        'Sota',
      );
      await tester.tap(find.byKey(const Key('login-submit')));

      // A new account sets up encryption and is shown its recovery key once.
      await pumpUntil(tester, find.byKey(const Key('create-recovery-key')));
      await tester.tap(find.byKey(const Key('create-recovery-key')));
      await pumpUntil(tester, find.byKey(const Key('recovery-key-text')));
      final recoveryKey = tester
          .widget<SelectableText>(find.byKey(const Key('recovery-key-text')))
          .data!;
      expect(recoveryKey, matches(RegExp(r'^([0-9A-Z]{4} ){13}[0-9A-Z]{3}$')));
      await tester.tap(find.byKey(const Key('recovery-key-stored')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('recovery-key-continue')));
      await pumpUntil(tester, find.text('Chats'));

      debugPrint('E2E step 3: Ask Kumiko to be a contact from the Contacts tab; she says yes.');
      await tester.tap(find.byTooltip('Contacts'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-contact')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('add-contact-field')), 'kumiko@test.local');
      await tester.tap(find.byKey(const Key('add-contact-confirm')));
      await pumpUntil(tester, find.byKey(const ValueKey('contact-request-kumiko@test.local')));
      const me = 'sota@test.local';
      await kumiko.repo.watchContacts().firstWhere((c) => c[me] == ContactState.incoming).timeout(const Duration(seconds: 30));
      await kumiko.repo.acceptContact(me);
      await pumpUntil(tester, find.byKey(const ValueKey('contact-profile-kumiko@test.local')));
      await tester.tap(find.byKey(const ValueKey('contact-profile-kumiko@test.local')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-message')));
      await pumpUntil(tester, find.byKey(const Key('composer-field')));
      // The lock in the title: the chat is end-to-end encrypted.
      expect(find.byTooltip('End-to-end encrypted'), findsOneWidget);

      debugPrint(
        'E2E step 4: Send a text; Kumiko decrypts it, the server cannot.',
      );
      await tester.enterText(
        find.byKey(const Key('composer-field')),
        'Hello from the desktop app!',
      );
      // The note about the contact request would cover the send button.
      ScaffoldMessenger.of(
        tester.element(find.byKey(const Key('composer-field'))),
      ).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('composer-send')));
      await pumpUntil(tester, said('Hello from the desktop app!'));
      final conv = await pumpUntilValue(tester, () async {
        final conversations = await kumiko.repo.watchConversations().first;
        return conversations.isEmpty ? null : conversations.single.id;
      }, reason: 'Kumiko sees the new chat');
      final first = await pumpUntilValue(
        tester,
        () => kumiko.messagesIf(conv, (l) => l.length == 1 && _decrypted(l)),
        reason: 'Kumiko decrypts the first message',
      );
      expect(first.single.envelope.text, 'Hello from the desktop app!');
      final stored = (await tester.runAsync(() => kumiko.api.history(conv)))!
          .messages
          .single;
      expect(stored.data['type'], 'mls.app');
      expect(
        jsonEncode(stored.data),
        isNot(contains('Hello from the desktop app')),
      );

      debugPrint('E2E step 5: Kumiko replies; it shows up live.');
      await tester.runAsync(() => kumiko.repo.sendText(conv, 'Hi Sota!'));
      await pumpUntil(tester, find.text('Hi Sota!'));

      debugPrint(
        'E2E step 6: Attachments (the picker itself needs a human, so call the repository).',
      );
      final repository = ProviderScope.containerOf(
        tester.element(find.byType(HanashiApp)),
      ).read(chatRepositoryProvider);
      final photo = File('${dir.path}/photo.png')
        ..writeAsBytesSync(
          img.encodePng(
            img.Image(width: 800, height: 600)
              ..clear(img.ColorRgb8(90, 160, 220)),
          ),
        );
      await tester.runAsync(
        () => repository.sendAttachment(
          conv,
          path: photo.path,
          name: 'photo.png',
        ),
      );

      final hasFfmpeg =
          (await tester.runAsync(() => Process.run('which', ['ffmpeg'])))!
              .exitCode ==
          0;
      if (hasFfmpeg) {
        final clip = '${dir.path}/clip.mp4';
        await tester.runAsync(
          () => Process.run('ffmpeg', [
            '-loglevel',
            'error',
            '-y',
            '-f',
            'lavfi',
            '-i',
            'testsrc=duration=3:size=640x360:rate=24',
            '-pix_fmt',
            'yuv420p',
            clip,
          ]),
        );
        await tester.runAsync(
          () => repository.sendAttachment(conv, path: clip, name: 'clip.mp4'),
        );
        // A Matroska video (WebM's container), and audio: Vorbis in WebM,
        // AAC in MP4 (.m4a).
        Future<void> make(String name, List<String> input) async {
          await tester.runAsync(
            () => Process.run('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'lavfi', ...input, '${dir.path}/$name']),
          );
          await tester.runAsync(() => repository.sendAttachment(conv, path: '${dir.path}/$name', name: name));
        }

        await make('clip.mkv', ['-i', 'testsrc=duration=2:size=320x240:rate=24', '-pix_fmt', 'yuv420p']);
        await make('voice.webm', ['-i', 'sine=duration=2', '-c:a', 'libvorbis']);
        await make('song.m4a', ['-i', 'sine=duration=3', '-c:a', 'aac']);
      }

      final expected = hasFfmpeg ? 7 : 3;
      final messages = await pumpUntilValue(
        tester,
        () => kumiko.messagesIf(
          conv,
          (l) => l.length == expected && _decrypted(l),
        ),
        reason: 'Kumiko decrypts the attachments',
        timeout: const Duration(seconds: 40),
      );

      final image = messages[2].envelope;
      expect(image.messageType, MessageType.image);
      expect((image.media!.width, image.media!.height), (800, 600));
      expect(image.media!.thumb, isNotNull);
      // Kumiko downloads the encrypted upload and decrypts it to the original.
      final received = (await tester.runAsync(
        () => kumiko.repo.mediaBytes(image.media!),
      ))!;
      expect(received, photo.readAsBytesSync());

      if (hasFfmpeg) {
        // Metadata and thumbnail come from libmpv on this device.
        final video = messages[3].envelope.media!;
        expect(messages[3].envelope.messageType, MessageType.video);
        expect((video.width, video.height), (640, 360));
        expect(video.durationMs, inInclusiveRange(2900, 3100));
        expect(
          video.thumb,
          isNotNull,
          reason: 'first frame should become the thumbnail',
        );
        final mkv = messages[4].envelope;
        expect((mkv.messageType, mkv.media!.mime, mkv.media!.width), (MessageType.video, 'video/x-matroska', 320));
        // Audio goes as files, with their length.
        final [voice, song] = [for (final m in messages.sublist(5)) m.envelope];
        expect((voice.messageType, voice.media!.mime), (MessageType.file, 'audio/webm'));
        expect(voice.media!.durationMs, inInclusiveRange(1900, 2100));
        expect((song.messageType, song.media!.mime), (MessageType.file, 'audio/mp4'));
        expect(song.media!.durationMs, inInclusiveRange(2900, 3100));
      }

      debugPrint(
        'E2E step 7: The image bubble renders the thumbnail from the local cache.',
      );
      await pumpUntil(tester, find.byType(Image));

      debugPrint('E2E step 8: Settings: notifications, and this device in the device list.');
      await tester.tap(find.byTooltip('Settings'));
      await pumpUntil(tester, find.text('Show notifications'));
      expect(find.text('sota@test.local\n$url'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('notifications-enabled'))).value, isTrue);
      // The device list is further down.
      await tester.scrollUntilVisible(find.text('Sign out of this device'), 300, scrollable: find.byType(Scrollable).last);
      await pumpUntil(tester, find.text('This device'));

      debugPrint('E2E step 9: Sign out returns to the login screen.');
      await tester.tap(find.text('Sign out of this device'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await pumpUntil(tester, find.byKey(const Key('login-submit')));

      debugPrint(
        'E2E step 10: Signing in again is a new device that must verify.',
      );
      await tester.enterText(find.widgetWithText(TextFormField, 'Server'), url);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'User name'),
        'sota',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'password123',
      );
      await tester.tap(find.byKey(const Key('login-submit')));
      await pumpUntil(tester, find.byKey(const Key('recovery-key-field')));
      await tester.enterText(
        find.byKey(const Key('recovery-key-field')),
        'AAAA BBBB',
      );
      await tester.tap(find.byKey(const Key('verify-submit')));
      await pumpUntil(tester, find.byKey(const Key('verify-error')));
      // A second enterText into the same field does not reach it in live
      // integration tests; set the text through the field's controller.
      tester
          .widget<TextField>(find.byKey(const Key('recovery-key-field')))
          .controller!
          .text = recoveryKey
          .toLowerCase();
      await tester.tap(find.byKey(const Key('verify-submit')));
      await pumpUntil(tester, find.byType(ChatList));
      // The new device synced the existing conversation and reads what was
      // said before it existed, with keys from the account's key backup.
      await pumpUntil(tester, find.text('kumiko'));
      await tester.tap(find.text('kumiko'));
      // The first messages are above the attachments: further back.
      final messageList = find.descendant(of: find.byType(ChatView), matching: find.byType(Scrollable));
      for (final text in ['Hi Sota!', 'Hello from the desktop app!']) {
        for (var i = 0; i < 100 && find.text(text).evaluate().isEmpty; i++) {
          if (messageList.evaluate().isNotEmpty) await tester.drag(messageList.first, const Offset(0, 300));
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text(text), findsOneWidget);
      }
      // Keys of what the scrolling loaded come from the backup a moment later.
      await pumpUntil(tester, find.text('Waiting for keys...'), gone: true);
      // Back to the newest.
      final position = tester.state<ScrollableState>(messageList.first).position;
      for (var i = 0; i < 50 && position.pixels > position.minScrollExtent; i++) {
        await tester.drag(messageList.first, const Offset(0, -600));
        await tester.pump(const Duration(milliseconds: 100));
      }

      debugPrint(
        'E2E step 11: The new device joined the group; new messages are readable.',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HanashiApp)),
      );
      final newDevice = container.read(accountProvider).value!.deviceId;
      await pumpUntilValue(tester, () async {
        final leaves = await kumiko.repo.groups.mls.members(conv);
        return leaves.any((l) => l.deviceId == newDevice) ? true : null;
      }, reason: "the new device appears in Kumiko's group");
      await tester.runAsync(
        () => kumiko.repo.sendText(conv, 'Welcome back, Sota!'),
      );
      await pumpUntil(tester, find.text('Welcome back, Sota!'));
      expect(find.byKey(const Key('security-banner')), findsNothing);

      debugPrint('E2E step 12: Verify Kumiko by comparing emoji.');
      await tester.tap(find.byKey(const Key('verify-contact')));
      final request = await pumpUntilValue(
        tester,
        () async => kumiko.verification.current
            .where((v) => v.incoming && v.state == SasState.requested)
            .firstOrNull,
        reason: "Kumiko's device gets the request",
      );
      await tester.runAsync(() => kumiko.verification.accept(request.txn));
      await pumpUntil(tester, find.byKey(const Key('verification-emoji')));
      // The app shows the emoji Kumiko's device computed, in order.
      final theirs = await pumpUntilValue(
        tester,
        () async => kumiko.verification.find(request.txn)?.emoji,
        reason: "Kumiko's emoji",
      );
      final shown = [
        for (final t in tester.widgetList<Text>(
          find.descendant(of: find.byKey(const Key('verification-emoji')), matching: find.byType(Text)),
        ))
          t.data,
      ];
      expect(shown, [for (final i in theirs) ...[sasEmoji[i].emoji, sasEmoji[i].name]]);
      await tester.tap(find.byKey(const Key('verification-match')));
      await tester.runAsync(() => kumiko.verification.confirm(request.txn));
      await pumpUntil(tester, find.byKey(const Key('verification-done')));
      await tester.tap(find.byKey(const Key('verification-done')));
      await pumpUntil(tester, find.byTooltip('kumiko is verified'));
      // Kumiko's side counts Sota as verified too.
      await pumpUntilValue(
        tester,
        () async => (await kumiko.repo.watchVerifiedUsers().first).contains('sota@test.local') ? true : null,
        reason: 'Kumiko verified Sota',
      );
      // Asked by a contact: the app prompts wherever the user is.
      final asked = await tester.runAsync(() => kumiko.verification.requestUserVerification('sota@test.local'));
      await pumpUntil(tester, find.byKey(const Key('verification-accept')));
      expect(find.text('Verify kumiko?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('verification-accept')));
      await pumpUntil(tester, find.byKey(const Key('verification-emoji')));
      // Kumiko's device has its emoji too, a moment later: only then can it
      // confirm them.
      await pumpUntilValue(tester, () async => kumiko.verification.find(asked!)?.emoji, reason: "Kumiko's emoji");
      await tester.tap(find.byKey(const Key('verification-match')));
      await tester.runAsync(() => kumiko.verification.confirm(asked!));
      await pumpUntil(tester, find.byKey(const Key('verification-done')));
      await tester.tap(find.byKey(const Key('verification-done')));
      await tester.pump();
      expect(find.byKey(const Key('verification-dialog')), findsNothing);
      expect(kumiko.verification.find(asked!)?.done, isTrue);

      debugPrint('E2E step 13: React, reply, edit and delete from the message menu.');
      await tester.tap(said('Welcome back, Sota!'), buttons: kSecondaryButton);
      await pumpUntil(tester, find.byKey(const ValueKey('react-👍')));
      await tester.pump(const Duration(milliseconds: 500)); // Opened all the way.
      await tester.tap(find.byKey(const ValueKey('react-👍')));
      await pumpUntilValue(
        tester,
        () => kumiko.messagesIf(
          conv,
          (l) => l.any((m) => m.envelope.text == 'Welcome back, Sota!' && m.reactions['👍'] != null),
        ),
        reason: "Kumiko sees Sota's reaction",
      );
      await tester.longPress(said('Welcome back, Sota!'));
      await pumpUntil(tester, find.byKey(const ValueKey('action-reply')));
      await tester.pump(const Duration(milliseconds: 500)); // Opened all the way.
      await tester.tap(find.byKey(const ValueKey('action-reply')));
      await pumpUntil(tester, find.byKey(const Key('composer-mode')));
      await tester.enterText(find.byKey(const Key('composer-field')), 'Glad to be back');
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-send')));
      final reply = await pumpUntilValue(
        tester,
        () async => (await kumiko.messagesIf(conv, (l) => l.last.envelope.text == 'Glad to be back'))?.last,
        reason: "Kumiko gets Sota's reply",
      );
      expect(reply.replyTo!.text, 'Welcome back, Sota!');

      await pumpUntil(tester, said('Glad to be back'));
      // A right click: the live test binding swallows the pointer cancel that
      // a sheet opening mid-press sends, so a second long press on the same
      // bubble would not register (real input is fine).
      await tester.tap(said('Glad to be back'), buttons: kSecondaryButton);
      await pumpUntil(tester, find.byKey(const ValueKey('action-edit')));
      await tester.pump(const Duration(milliseconds: 500)); // Opened all the way.
      await tester.tap(find.byKey(const ValueKey('action-edit')));
      await pumpUntil(tester, find.byKey(const Key('composer-mode')));
      await tester.enterText(find.byKey(const Key('composer-field')), 'So glad to be back');
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-send')));
      await pumpUntilValue(
        tester,
        () => kumiko.messagesIf(conv, (l) => l.last.envelope.text == 'So glad to be back' && l.last.edited),
        reason: "Kumiko sees Sota's edit",
      );
      await pumpUntil(tester, said('So glad to be back'));
      await tester.tap(said('So glad to be back'), buttons: kSecondaryButton);
      await pumpUntil(tester, find.byKey(const ValueKey('action-delete')));
      await tester.pump(const Duration(milliseconds: 500)); // Opened all the way.
      await tester.tap(find.byKey(const ValueKey('action-delete')));
      await pumpUntil(tester, find.byKey(const Key('delete-confirm')));
      await tester.tap(find.byKey(const Key('delete-confirm')));
      await pumpUntil(tester, find.byKey(const Key('deleted-message')));
      await pumpUntilValue(
        tester,
        () => kumiko.messagesIf(conv, (l) => l.last.id == reply.id && l.last.isDeleted),
        reason: "Sota's message is deleted on Kumiko's device",
      );

      debugPrint('E2E step 14: Write with the emoji panel; the emoji arrive.');
      // Focus went to the dialog; enterText alone does not bring it back.
      await tester.tap(find.byKey(const Key('composer-field')));
      await tester.enterText(find.byKey(const Key('composer-field')), 'Parfait ');
      await tester.tap(find.byKey(const Key('composer-emoji')));
      await pumpUntil(tester, find.byIcon(Icons.tag_faces));
      await tester.tap(find.byIcon(Icons.tag_faces)); // Smileys.
      await pumpUntil(tester, find.text('😀'));
      await tester.pump(const Duration(milliseconds: 500)); // The tab animation.
      await tester.tap(find.text('😀').first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-send')));
      await pumpUntilValue(
        tester,
        () => kumiko.messagesIf(conv, (l) => l.last.envelope.text == 'Parfait 😀'),
        reason: 'Kumiko gets the emoji',
      );

      await tester.runAsync(kumiko.close);
      // Stop the app, its screens and its sync, before its database goes away.
      final current = container.read(chatRepositoryProvider);
      await tester.pumpWidget(const SizedBox());
      if (current is ServerChatRepository) await tester.runAsync(current.dispose);
      await tester.runAsync(db.close);
    },
  );
}
