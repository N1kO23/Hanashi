import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/calls/livekit_connection.dart';

void main() {
  var now = DateTime(2026, 11, 8, 12);
  void later(int ms) => now = now.add(Duration(milliseconds: ms));
  late UnheardAudio unheard;
  bool heard(String who, {bool muted = false}) => unheard.unheardIn(who, muted: muted) != Duration.zero;

  setUp(() => unheard = UnheardAudio(clock: () => now));

  test('audio that does not decrypt counts as unheard once it has not for a while', () {
    expect(unheard.unheardIn('kumiko/phone', muted: false), isNull);
    unheard.failed('kumiko/phone');
    expect(unheard.unheardIn('kumiko/phone', muted: false), const Duration(seconds: 2));
    later(1500);
    // Told again (another failure): still counted from the first.
    unheard.failed('kumiko/phone');
    expect(unheard.unheardIn('kumiko/phone', muted: false), const Duration(milliseconds: 500));
    later(500);
    expect(heard('kumiko/phone'), isFalse);
    expect(heard('hotaru/desktop'), isTrue, reason: 'only the one failing');
    unheard.decrypted('kumiko/phone');
    expect(unheard.unheardIn('kumiko/phone', muted: false), isNull);
  });

  test("muted: LiveKit's own frames fail, and that is no matter, then or once unmuted", () {
    // The server's second of silence, maybe before this device is told of
    // the muting.
    unheard.failed('kumiko/phone');
    later(300);
    expect(unheard.unheardIn('kumiko/phone', muted: true), isNull);
    later(60000);
    expect(heard('kumiko/phone', muted: true), isTrue);
    // Unmuted: its frames have a while to decrypt.
    unheard.audible('kumiko/phone');
    expect(heard('kumiko/phone'), isTrue);
    later(400);
    unheard.decrypted('kumiko/phone');
    later(5000);
    expect(heard('kumiko/phone'), isTrue);
  });

  test('unmuted with a key this device does not have: unheard after the while', () {
    unheard.failed('kumiko/phone');
    later(60000);
    unheard.audible('kumiko/phone');
    unheard.failed('kumiko/phone');
    later(1999);
    expect(heard('kumiko/phone'), isTrue);
    later(1);
    expect(heard('kumiko/phone'), isFalse);
    // Not failing: nothing to count again.
    unheard.decrypted('kumiko/phone');
    unheard.audible('kumiko/phone');
    expect(unheard.unheardIn('kumiko/phone', muted: false), isNull);
  });
}
