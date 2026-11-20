import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/data/sync_lock.dart';

void main() {
  test('one holder per device; others can wake it; released on close', () async {
    final app = SyncLock('device-1');
    final push = SyncLock('device-1');
    final otherDevice = SyncLock('device-2');
    addTearDown(() => Future.wait([app.close(), push.close(), otherDevice.close()]));

    expect(await SyncLock.wakeHolder('device-1'), isFalse);
    expect(app.tryAcquire(), isTrue);
    expect(push.tryAcquire(), isFalse);
    expect(otherDevice.tryAcquire(), isTrue);

    final woken = app.wakeups.first;
    expect(await SyncLock.wakeHolder('device-1'), isTrue);
    await woken.timeout(const Duration(seconds: 2));

    final waiting = push.acquire(poll: const Duration(milliseconds: 10));
    await app.close();
    expect(await waiting, isTrue);
    expect(push.held, isTrue);
  });

  test('waiting can be cancelled', () async {
    final holder = SyncLock('device-3');
    final waiter = SyncLock('device-3');
    addTearDown(() => Future.wait([holder.close(), waiter.close()]));
    holder.tryAcquire();
    var cancelled = false;
    final waiting = waiter.acquire(cancelled: () => cancelled, poll: const Duration(milliseconds: 10));
    cancelled = true;
    expect(await waiting, isFalse);
  });

  test('a holder that is gone without releasing the lock does not keep it', () async {
    // What an engine leaves behind when Android ends it: its name, and nobody
    // answering at it.
    final gone = ReceivePort();
    IsolateNameServer.registerPortWithName(gone.sendPort, SyncLock.nameFor('device-4'));
    gone.close();
    const answerWithin = Duration(milliseconds: 200);

    // A push no longer asks it to sync, and then can.
    expect(await SyncLock.wakeHolder('device-4', answerWithin: answerWithin), isFalse);
    final push = SyncLock('device-4');
    expect(push.tryAcquire(), isTrue);
    await push.close();

    // The app, waiting for the lock, takes it over.
    IsolateNameServer.registerPortWithName((ReceivePort()..close()).sendPort, SyncLock.nameFor('device-4'));
    final app = SyncLock('device-4');
    addTearDown(app.close);
    expect(await app.acquire(answerWithin: answerWithin), isTrue);

    // A live holder answers, and keeps it.
    final waiter = SyncLock('device-4');
    addTearDown(waiter.close);
    var stop = false;
    final waiting = waiter.acquire(cancelled: () => stop, poll: const Duration(milliseconds: 10), answerWithin: answerWithin);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(app.held, isTrue);
    stop = true;
    expect(await waiting, isFalse);
  });
}
