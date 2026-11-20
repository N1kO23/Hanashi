import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

/// Lets only one Flutter engine in the process sync a device at a time:
/// syncing opens the device's MLS state, and two copies of it would drift
/// apart. On Android a push starts a second, headless engine next to the
/// app's own; both see the same [IsolateNameServer].
///
/// The holder also gets wake-ups: another engine that received a push asks
/// it to sync now instead of syncing itself.
///
/// Android can end an engine without running any Dart clean-up (the app
/// swiped away while the process lives on for pushes), leaving its name in
/// the [IsolateNameServer] with nobody behind it. So a holder answers when
/// asked, and one that does not is taken to be gone (see [_holder]).
class SyncLock {
  SyncLock(String deviceId) : name = nameFor(deviceId) {
    _wakeupSubscription = _port.listen((message) {
      // An engine asking whether this one still holds the lock.
      if (message is SendPort) {
        message.send(true);
      } else {
        _wakeups.add(null);
      }
    });
  }

  /// How long a holder has to answer. A live one answers at once: neither
  /// the database nor MLS work runs on the engine's own isolate.
  static const answerWithin = Duration(seconds: 5);

  final String name;
  final _port = ReceivePort();
  final _wakeups = StreamController<void>.broadcast(sync: true);
  late final StreamSubscription<Object?> _wakeupSubscription;
  var _held = false;
  var _closed = false;

  static String nameFor(String deviceId) => 'hanashi.sync.$deviceId';

  bool get held => _held;

  /// Requests from other engines to sync now, while this lock is held.
  Stream<void> get wakeups => _wakeups.stream;

  /// Takes the lock if nobody holds it.
  bool tryAcquire() {
    if (_closed) return false;
    return _held = _held || IsolateNameServer.registerPortWithName(_port.sendPort, name);
  }

  /// Waits for the lock; completes false if [cancelled] or [close]d first.
  Future<bool> acquire({
    bool Function()? cancelled,
    Duration poll = const Duration(milliseconds: 100),
    Duration answerWithin = answerWithin,
  }) async {
    // Whether the holder is there at all, now and then: one releasing the
    // lock as usual is noticed sooner by trying to take it.
    Stopwatch? sinceAsked;
    while (!tryAcquire()) {
      if (_closed || (cancelled?.call() ?? false)) return false;
      if (sinceAsked == null || sinceAsked.elapsed >= answerWithin) {
        sinceAsked = Stopwatch()..start();
        if (await _holder(name, answerWithin) == null) continue; // It was gone: try again at once.
      }
      await Future<void>.delayed(poll);
    }
    return true;
  }

  void release() {
    if (!_held) return;
    _held = false;
    IsolateNameServer.removePortNameMapping(name);
  }

  /// Releases the lock for good.
  Future<void> close() async {
    _closed = true;
    release();
    await _wakeupSubscription.cancel();
    _port.close();
    await _wakeups.close();
  }

  /// Asks whoever holds the lock for [deviceId] to sync now. Returns false
  /// if nobody holds it, or the holder is gone.
  static Future<bool> wakeHolder(String deviceId, {Duration answerWithin = answerWithin}) async {
    final port = await _holder(nameFor(deviceId), answerWithin);
    port?.send(null);
    return port != null;
  }

  /// The holder of the lock [name], if it answers. One that does not is
  /// gone, and its name is removed so that the lock can be taken. Null also
  /// when the lock changed hands meanwhile: a holder releasing it drops the
  /// question unanswered.
  static Future<SendPort?> _holder(String name, Duration answerWithin) async {
    final port = IsolateNameServer.lookupPortByName(name);
    if (port == null) return null;
    final answer = ReceivePort();
    final answered = answer.first.then((_) => true, onError: (Object _) => false);
    final waited = Stopwatch()..start();
    try {
      port.send(answer.sendPort);
      while (waited.elapsed < answerWithin) {
        if (await answered.timeout(const Duration(milliseconds: 50), onTimeout: () => false)) return port;
        if (IsolateNameServer.lookupPortByName(name) != port) return null;
      }
    } finally {
      answer.close();
    }
    // Unless another engine took the lock this very moment.
    if (IsolateNameServer.lookupPortByName(name) == port) IsolateNameServer.removePortNameMapping(name);
    return null;
  }
}
