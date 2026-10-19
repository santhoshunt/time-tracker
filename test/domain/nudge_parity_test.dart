import 'dart:convert';
import 'dart:io';

import 'package:drift_time/domain/nudge_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every case in test/fixtures/nudge_cases.json, which NudgeDeciderTest.kt
/// also runs, so Dart and the Android service decide alike.
void main() {
  final fixture =
      jsonDecode(File('test/fixtures/nudge_cases.json').readAsStringSync())
          as Map<String, dynamic>;
  final snapshots = {
    for (final e in (fixture['snapshots'] as Map<String, dynamic>).entries)
      e.key: NudgeSnapshot.fromJson(e.value as Map<String, dynamic>),
  };

  test('the fixture has cases for every rule', () {
    expect((fixture['cases'] as List).length, greaterThanOrEqualTo(19));
  });

  for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    test(c['name'], () {
      final decision = decideNudge(
        snapshots[c['snapshot']]!,
        nowMs: c['nowMs'] as int,
        nowLocalMin: c['nowLocalMin'] as int,
        pkg: c['pkg'] as String,
        category: c['category'] as String,
        continuousMs: c['continuousMs'] as int,
        lastNudgeMs: c['lastNudgeMs'] as int?,
        snoozedUntilMs: c['snoozedUntilMs'] as int?,
      );
      final expected = c['expect'] as Map<String, dynamic>;
      if (expected['nudge'] == true) {
        expect(decision, isA<Nudge>());
        final n = decision as Nudge;
        expect(n.block, expected['block']);
        expect(n.minutesOff, expected['minutesOff']);
        expect(n.minutesLeft, expected['minutesLeft']);
      } else {
        expect(decision, isA<NoNudge>());
      }
    });
  }

  test('a snapshot survives a JSON round trip', () {
    final base = snapshots['base']!;
    final again = NudgeSnapshot.fromJson(
      jsonDecode(jsonEncode(base.toJson())) as Map<String, dynamic>,
    );
    expect(jsonEncode(again.toJson()), jsonEncode(base.toJson()));
  });
}
