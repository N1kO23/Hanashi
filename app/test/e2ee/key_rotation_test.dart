import 'package:flutter_test/flutter_test.dart';
import 'package:hanashi/e2ee/group_manager.dart';

void main() {
  final rotatedAt = DateTime(2026, 10, 1);

  test('keys rotate after 100 messages or 7 days, whichever comes first', () {
    bool due(int sentSince, Duration age) =>
        keyRotationDue(rotatedAt: rotatedAt, sentSince: sentSince, now: rotatedAt.add(age));

    expect(due(0, Duration.zero), isFalse);
    expect(due(99, const Duration(days: 6, hours: 23)), isFalse);
    expect(due(100, Duration.zero), isTrue);
    expect(due(0, const Duration(days: 7)), isTrue);
  });
}
