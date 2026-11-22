import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/data/mock_chat_repository.dart';
import 'package:material_ui/material_ui.dart';

import 'support/test_app.dart';

/// Hubs that cannot be reached, as the test says.
class _Hubs extends MockChatRepository {
  _Hubs() : super(latency: Duration.zero, autoReply: false, now: testNow);

  final unreachable = StreamController<Map<String, String>>.broadcast();

  @override
  Stream<Map<String, String>> watchUnreachableHubs() => unreachable.stream;
}

void main() {
  testWidgets("a chat says why its messages wait while its server can't be reached", (tester) async {
    await setSurfaceSize(tester, const Size(1200, 800));
    final repo = _Hubs();
    addTearDown(repo.unreachable.close);
    await tester.pumpWidget(testApp(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club Room'));
    await tester.pumpAndSettle();
    final banner = find.byKey(const Key('hub-banner'));
    expect(banner, findsNothing);
    // The stream's news, then the frame it shows in.
    Future<void> hubs(Map<String, String> unreachable) async {
      repo.unreachable.add(unreachable);
      await tester.pump();
      await tester.pump();
    }

    await hubs({'club': 'chat.example.org'});
    expect(
      find.descendant(
        of: banner,
        matching: find.text(
          "chat.example.org, the server this chat runs on, can't be reached right now, so messages here wait. "
          "They're sent once it's back.",
        ),
      ),
      findsOneWidget,
    );

    // Another chat's server is that chat's business.
    await hubs({'dm-naoko': 'other.example'});
    expect(banner, findsNothing);

    // Without the server's name.
    await hubs({'club': ''});
    expect(find.textContaining("The server this chat runs on can't be reached"), findsOneWidget);

    await hubs(const {});
    expect(banner, findsNothing);
  });
}
