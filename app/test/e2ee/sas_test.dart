import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/e2ee/sas.dart';

const alice = SasParty('sota@test.local', 'NEWDEVICE');
const bob = SasParty('sota@test.local', 'OLDDEVICE');
const mallory = SasParty('mallory@test.local', 'EVIL');

/// Delivers messages between sessions until nothing is left to send.
Future<void> exchange(
  Map<SasParty, SasSession> sessions,
  List<(SasParty from, SasParty to, SasMessage m)> queue,
) async {
  while (queue.isNotEmpty) {
    final (from, to, m) = queue.removeAt(0);
    final session = sessions[to]!;
    for (final reply in await session.handle(m.type, m.data, from)) {
      queue.add((to, from, reply));
    }
  }
}

void main() {
  late SasSession initiator;
  late SasSession responder;

  setUp(() {
    initiator = SasSession.initiator(txn: 'T1', us: alice, ourKeys: {'device:NEWDEVICE': 'mls-key'})
      ..expectedKeys = {'identity': 'id-key'};
    responder = SasSession.responder(txn: 'T1', us: bob, them: alice, ourKeys: {'identity': 'id-key'})
      ..expectedKeys = {'device:NEWDEVICE': 'mls-key'};
  });

  Future<void> runToEmoji() async {
    final sessions = {alice: initiator, bob: responder};
    final request = initiator.request(mode: 'device');
    expect(request.type, SasType.request);
    await exchange(sessions, [(bob, alice, await responder.accept())]);
  }

  test('both devices show the same emoji, verify each other and can pass a secret', () async {
    await runToEmoji();
    expect(initiator.state, SasState.comparing);
    expect(responder.state, SasState.comparing);
    expect(initiator.emoji, hasLength(7));
    expect(initiator.emoji, responder.emoji);
    expect(initiator.emoji!.every((i) => i >= 0 && i < sasEmoji.length), isTrue);

    final sessions = {alice: initiator, bob: responder};
    await exchange(sessions, [for (final m in await responder.confirm()) (bob, alice, m)]);
    expect(responder.state, SasState.waitingForOther);
    // The initiator's MAC arrives after it confirms.
    await exchange(sessions, [for (final m in await initiator.confirm()) (alice, bob, m)]);
    expect(initiator.state, SasState.verified);
    expect(responder.state, SasState.verified);

    final sealed = await responder.seal(utf8.encode('account secrets'));
    expect(utf8.decode(await initiator.open(sealed)), 'account secrets');
  });

  test('a device that vouches for a different key is refused', () async {
    responder.expectedKeys = {'device:NEWDEVICE': 'a key the server showed'};
    await runToEmoji();
    final sessions = {alice: initiator, bob: responder};
    await exchange(sessions, [for (final m in await initiator.confirm()) (alice, bob, m)]);
    final replies = await responder.confirm();
    expect(responder.state, SasState.cancelled);
    expect(replies.last.type, SasType.cancel);
    expect(responder.cancelReason, 'The keys do not match');
  });

  test('a server in the middle cannot make both sides see the same emoji', () async {
    // Mallory runs one exchange with each side and relays the rest.
    final toAlice = SasSession.responder(txn: 'T1', us: bob, them: alice, ourKeys: const {});
    final toBob = SasSession.initiator(txn: 'T1', us: alice, ourKeys: const {});
    await exchange({alice: initiator, bob: toAlice}, [(bob, alice, await toAlice.accept())]);
    toBob.request(mode: 'device');
    await exchange({alice: toBob, bob: responder}, [(bob, alice, await responder.accept())]);
    expect(initiator.state, SasState.comparing);
    expect(responder.state, SasState.comparing);
    expect(initiator.emoji, isNot(responder.emoji));
  });

  test('the responder cannot swap its key after committing to one', () async {
    initiator.request(mode: 'device');
    final accept = await responder.accept();
    final replies = await initiator.handle(accept.type, accept.data, bob);
    expect(replies.single.type, SasType.key);
    // A different responder key than the committed one.
    final other = SasSession.responder(txn: 'T1', us: bob, them: alice, ourKeys: const {});
    await other.accept();
    final otherKey = (await other.handle(SasType.key, replies.single.data, alice)).single;
    final cancel = await initiator.handle(otherKey.type, otherKey.data, bob);
    expect(cancel.single.type, SasType.cancel);
    expect(initiator.state, SasState.cancelled);
  });

  test('messages from other devices, other sessions and repeats are ignored', () async {
    await runToEmoji();
    expect(await initiator.handle(SasType.key, {'txn': 'T1', 'key': 'x'}, mallory), isEmpty);
    expect(await initiator.handle(SasType.mac, {'txn': 'OTHER', 'mac': 'x'}, bob), isEmpty);
    expect(await initiator.handle(SasType.accept, {'txn': 'T1', 'commitment': 'x'}, bob), isEmpty);
    expect(initiator.state, SasState.comparing);
    await initiator.handle(SasType.cancel, {'txn': 'T1', 'reason': 'They do not match'}, bob);
    expect((initiator.state, initiator.cancelReason), (SasState.cancelled, 'They do not match'));
  });

  test('secrets cannot be sealed before verification', () async {
    await runToEmoji();
    expect(() => responder.seal([1, 2, 3]), throwsStateError);
  });
}
