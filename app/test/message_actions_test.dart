import 'package:drift/native.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hanashi/data/local/database.dart';
import 'package:hanashi/state/providers.dart';
import 'package:hanashi/ui/chat/message_bubble.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_app.dart';

void main() {
  Future<void> openClubRoom(WidgetTester tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(testApp(testRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
  }

  /// [text] as a message says it, not where a reply quotes it.
  Finder said(String text) => find.byElementPredicate((e) {
    if (e.widget case Text(:final data, :final textSpan) when (data ?? textSpan?.toPlainText()) == text) {
      var quoted = false;
      e.visitAncestorElements((a) => !(quoted = a.widget.key == const Key('reply-quote')));
      return !quoted;
    }
    return false;
  });

  MessageBubble bubbleWith(WidgetTester tester, String text) =>
      tester.widget<MessageBubble>(find.ancestor(of: said(text), matching: find.byType(MessageBubble)));

  testWidgets('several reactions from a long press; tapping your own takes it back', (tester) async {
    await openClubRoom(tester);
    const question = 'Is everyone coming to the meeting later?';
    Future<void> pick(String emoji) async {
      await tester.longPress(said(question));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('react-$emoji')));
      await tester.pumpAndSettle();
    }

    await pick('😂');
    await pick('👍');
    expect(bubbleWith(tester, question).message.reactions, {
      '😂': ['sota@localhost'],
      '👍': ['sota@localhost'],
    });
    await pick('😂');
    expect(bubbleWith(tester, question).message.reactions, {
      '👍': ['sota@localhost'],
    });

    // A chip adds the user's reaction next to the others', then takes it back.
    Finder chip(String text, String emoji) => find.descendant(
      of: find.ancestor(of: said(text), matching: find.byType(MessageBubble)),
      matching: find.byKey(ValueKey('reaction-$emoji')),
    );
    const snacks = 'Yes! I will bring snacks.';
    await tester.tap(chip(snacks, '👍'));
    await tester.pumpAndSettle();
    expect(bubbleWith(tester, snacks).message.reactions, {
      '👍': ['aiko@localhost', 'kumiko@localhost', 'sota@localhost'],
      '❤️': ['sota@localhost'],
    });
    await tester.tap(chip(snacks, '👍'));
    await tester.pumpAndSettle();
    expect(bubbleWith(tester, snacks).message.reactions, {
      '👍': ['aiko@localhost', 'kumiko@localhost'],
      '❤️': ['sota@localhost'],
    });
  });

  testWidgets('the quick reactions put the ones used lately first', (tester) async {
    SharedPreferences.setMockInitialValues({}); // Where the picker keeps recent emoji.
    await openClubRoom(tester);
    const question = 'Is everyone coming to the meeting later?';
    Future<List<String>> quick() async {
      await tester.longPress(said(question));
      await tester.pumpAndSettle();
      return [
        for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String>).evaluate())
          if ((e.widget.key! as ValueKey<String>).value case final key when key.startsWith('react-') && key != 'react-more')
            key.substring('react-'.length),
      ];
    }

    expect(await quick(), ['👍', '❤️', '😂', '😮', '😢', '🙏']);
    // Any emoji from the picker.
    await tester.tap(find.byKey(const Key('react-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tag_faces));
    await tester.pumpAndSettle();
    await tester.tap(find.text('😀').first);
    await tester.pumpAndSettle();
    expect(await quick(), ['😀', '👍', '❤️', '😂', '😮', '😢']);
    await tester.tap(find.byKey(const ValueKey('react-😮')));
    await tester.pumpAndSettle();
    // Taking one back changes nothing.
    expect(await quick(), ['😮', '😀', '👍', '❤️', '😂', '😢']);
    await tester.tap(find.byKey(const ValueKey('react-😀')));
    await tester.pumpAndSettle();
    expect(bubbleWith(tester, question).message.reactions, {'😮': ['sota@localhost']});
    expect(await quick(), ['😮', '😀', '👍', '❤️', '😂', '😢']);
    // The picker keeps its own recent emoji in memory: not for other tests.
    await EmojiPickerUtils().clearRecentEmojis(key: GlobalKey<EmojiPickerState>());
  });

  test('recent reactions are remembered after a restart', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    ProviderContainer app() => ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    final before = app();
    before.read(recentReactionsProvider.notifier)
      ..use('🎉')
      ..use('👍');
    await Future<void>.delayed(const Duration(milliseconds: 50)); // Saved.
    before.dispose();

    final after = app();
    addTearDown(after.dispose);
    after.read(recentReactionsProvider);
    for (var i = 0; i < 50 && after.read(recentReactionsProvider).isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(after.read(recentReactionsProvider), ['👍', '🎉']);
  });

  testWidgets('any emoji from the picker', (tester) async {
    await openClubRoom(tester);
    await tester.tap(said('Is everyone coming to the meeting later?'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('react-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('emoji-picker')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // Closed without choosing.
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('emoji-picker')), findsNothing);
    expect(bubbleWith(tester, 'Is everyone coming to the meeting later?').message.reactions, isEmpty);
  });

  testWidgets('reply from the right-click menu; the reply quotes the original', (tester) async {
    await openClubRoom(tester);
    await tester.tap(said('Yes! I will bring snacks.'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-reply')));
    await tester.pumpAndSettle();
    expect(find.text('Replying to Yoko'), findsOneWidget);

    // Escape stops replying; replying again and sending quotes the message.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-mode')), findsNothing);
    await tester.longPress(said('Yes! I will bring snacks.'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-reply')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('composer-field')), 'Chocolate please');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-mode')), findsNothing);
    final reply = bubbleWith(tester, 'Chocolate please').message;
    expect((reply.replyTo!.from, reply.replyTo!.text), ('yoko@localhost', 'Yes! I will bring snacks.'));
  });

  testWidgets('tapping a quote shows the original', (tester) async {
    await openClubRoom(tester);
    final quote = find.descendant(
      of: find.ancestor(of: said('I will be a little late, start without me.'), matching: find.byType(MessageBubble)),
      matching: find.byKey(const Key('reply-quote')),
    );
    await tester.tap(quote);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(bubbleWith(tester, 'Is everyone coming to the meeting later?').highlighted, isTrue);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(bubbleWith(tester, 'Is everyone coming to the meeting later?').highlighted, isFalse);
  });

  testWidgets('edit and delete your own message', (tester) async {
    await openClubRoom(tester);
    const mine = 'I will be a little late, start without me.';
    // Only your own messages can be edited or deleted.
    await tester.longPress(said('Yes! I will bring snacks.'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-edit')), findsNothing);
    expect(find.byKey(const ValueKey('action-delete')), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.longPress(said(mine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-edit')));
    await tester.pumpAndSettle();
    expect(find.text('Edit message'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('composer-field')), 'I will be on time after all.');
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    expect(said(mine), findsNothing);
    expect(bubbleWith(tester, 'I will be on time after all.').message.edited, isTrue);
    expect(find.textContaining('edited'), findsOneWidget);

    await tester.longPress(said('I will be on time after all.'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-confirm')));
    await tester.pumpAndSettle();
    expect(said('I will be on time after all.'), findsNothing);
    expect(find.byKey(const Key('deleted-message')), findsOneWidget);
  });

  testWidgets('change your display name in Settings', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(testApp(testRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('edit-profile')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('display-name-field')), 'Sota of Minato');
    await tester.pump();
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('display-name-field')), findsNothing);
    expect(find.text('Sota of Minato'), findsOneWidget);
  });

  testWidgets('the emoji button opens a panel; its emoji go into the message', (tester) async {
    SharedPreferences.setMockInitialValues({}); // Where the picker keeps recent emoji.
    await openClubRoom(tester);
    await tester.enterText(find.byKey(const Key('composer-field')), 'Snacks ');
    await tester.tap(find.byKey(const Key('composer-emoji')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-emoji-picker')), findsOneWidget);
    expect(find.text('Emoji you use show up here'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.tag_faces)); // Smileys.
    await tester.pumpAndSettle();
    await tester.tap(find.text('😀').first);
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(const Key('composer-field')));
    expect(field.controller!.text, 'Snacks 😀');
    // On a phone, the keyboard takes the panel's place again.
    await tester.tap(find.byKey(const Key('composer-field')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('expression-panel')), findsNothing);
    // Sent like anything typed.
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    expect(said('Snacks 😀'), findsOneWidget);
  });

  testWidgets('with a mouse: hover buttons react and reply; emoji go into the text; Escape closes the panel', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await openClubRoom(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(said('Yes! I will bring snacks.')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hover-actions')), findsOneWidget);

    await tester.tap(find.byKey(const Key('hover-react')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-reply')), findsNothing); // Only reactions.
    await tester.tap(find.byKey(const ValueKey('react-😮')));
    await tester.pumpAndSettle();
    expect(bubbleWith(tester, 'Yes! I will bring snacks.').message.reactions['😮'], ['sota@localhost']);

    await mouse.moveTo(tester.getCenter(said('Is everyone coming to the meeting later?')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hover-reply')));
    await tester.pumpAndSettle();
    expect(find.text('Replying to Aiko'), findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hover-actions')), findsNothing);

    // Emoji go where the cursor is, also when the field lost focus to the
    // panel's clicks.
    SharedPreferences.setMockInitialValues({});
    await tester.enterText(find.byKey(const Key('composer-field')), 'Snacks ');
    await tester.tap(find.byKey(const Key('composer-emoji')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tag_faces));
    await tester.pumpAndSettle();
    await tester.tap(find.text('😀').first);
    await tester.pump();
    await tester.tap(find.text('😀').first);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('composer-field'))).controller!.text, 'Snacks 😀😀');

    // Escape closes the panel first, then stops replying.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('expression-panel')), findsNothing);
    expect(find.text('Replying to Aiko'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-mode')), findsNothing);
    await mouse.removePointer();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets("with a mouse: hovering moves nothing; the bar sits on the bubble's corner and stays under the pointer", (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await openClubRoom(tester);
    // A narrow window, where a bar beside the bubble used to squash it.
    await setSurfaceSize(tester, const Size(560, 800));
    await tester.pumpAndSettle();
    const theirs = 'Is everyone coming to the meeting later?';
    const mine = 'I will be a little late, start without me.';
    Rect bubble(String text) =>
        // The bubble: what the bar is anchored to.
        tester.getRect(find.ancestor(of: said(text), matching: find.byType(OverlayPortal)).first);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);

    for (final (text, isMine) in [(theirs, false), (mine, true)]) {
      final before = bubble(text);
      await mouse.moveTo(before.center);
      await tester.pumpAndSettle();
      expect(bubble(text), before, reason: 'the bar takes no room: $text');
      final bar = tester.getRect(find.byKey(const Key('hover-actions')));
      // Across the bubble's top edge, over the corner facing the middle.
      expect(bar.top < before.top && bar.bottom > before.top, isTrue, reason: '$bar, bubble $before');
      expect(
        isMine ? bar.left < before.left && bar.right > before.left : bar.left < before.right && bar.right > before.right,
        isTrue,
        reason: '$bar, bubble $before',
      );
      // Onto the bar: it stays.
      await mouse.moveTo(tester.getCenter(find.byKey(const Key('hover-reply'))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hover-actions')), findsOneWidget);
    }
    // And it works from there.
    await tester.tap(find.byKey(const Key('hover-reply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-mode')), findsOneWidget);

    // Off both: gone.
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hover-actions')), findsNothing);
    await mouse.removePointer();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('photos and files can be downloaded from the actions', (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    await tester.pumpWidget(testApp(testRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Naoko'));
    await tester.pumpAndSettle();

    // A text has nothing to download.
    await tester.tap(said('Thank you, I will read it tonight.'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-reply')), findsOneWidget);
    expect(find.byKey(const ValueKey('action-download')), findsNothing);
    await tester.tapAt(const Offset(10, 10)); // Closes the menu.
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.image_outlined).first, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-download')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('weekly-report.pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-download')));
    await tester.pumpAndSettle();
    // Saving it was tried, and failed: the demo has no files, and no
    // Downloads folder in tests.
    expect(find.textContaining('Could not save the file'), findsOneWidget);
  });
}
