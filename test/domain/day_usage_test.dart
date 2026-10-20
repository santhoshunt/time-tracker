import 'dart:convert';
import 'dart:io';

import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/category_guess.dart';
import 'package:drift_time/domain/day_usage.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/domain/nudge_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

Set<String> _set(Object? list) => {for (final p in list as List<dynamic>) p as String};

/// Every case in test/fixtures/usage_count_cases.json, which DayUsageTest.kt
/// also runs, so the Today notification counts as the Usage tab does.
void main() {
  final fixture = jsonDecode(File('test/fixtures/usage_count_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  test('the fixture covers the rules', () {
    expect(cases.length, greaterThanOrEqualTo(18));
  });

  for (final c in cases) {
    test(c['name'], () {
      final events = [
        for (final e in (c['events'] as List).cast<Map<String, dynamic>>())
          RawEvent.fromMap({
            't': DateTime.parse(e['t'] as String).millisecondsSinceEpoch,
            'p': e['p'],
            'c': e['c'],
            'k': e['k'],
          })!,
      ];
      final counted = countDayUsage(
        events,
        dayStartMs: DateTime.parse(c['dayStart'] as String).millisecondsSinceEpoch,
        nowMs: DateTime.parse(c['now'] as String).millisecondsSinceEpoch,
        idlePackages: _set(c['idle']),
        launchable: _set(c['launchable']),
        categories: (c['categories'] as Map<String, dynamic>).cast<String, String>(),
        offApps: _set(c['offApps']),
        onApps: _set(c['onApps']),
        guessOff: _set(c['guessOff']),
      );
      final expected = c['expect'] as Map<String, dynamic>;
      expect(counted.totalMs, expected['totalMs'], reason: 'total');
      expect(counted.distractingMs, expected['distractingMs'], reason: 'distracting');
    });
  }

  group('isDistracting', () {
    bool d(String p, String category, {Set<String> off = const {}, Set<String> on = const {}}) =>
        isDistracting(p, category, offApps: off, onApps: on, guessOff: guessOffCategories);

    test('a guessed category counts unless an on-track rule says otherwise', () {
      expect(d('com.example.social', 'social'), isTrue);
      expect(d('com.example.chat', 'social', on: {'com.example.chat'}), isFalse);
    });

    test('an off-track rule counts whatever the category', () {
      expect(d('com.example.tool', 'productivity', off: {'com.example.tool'}), isTrue);
      expect(d('com.example.chat', 'social', off: {'com.example.chat'}, on: {'com.example.chat'}), isTrue);
    });

    test('an unruled productivity or unknown app does not count', () {
      expect(d('com.example.notes', 'productivity'), isFalse);
      expect(d('com.example.x', 'undefined'), isFalse);
    });

    test("the fixture's Drift package is Drift's", () {
      // day_usage.dart keeps its own copy to stay free of app wiring.
      expect(cases.any((c) => (c['idle'] as List).contains(driftPackage)), isTrue);
    });
  });

  test('rule sets: off for any block wins, on only when never off', () {
    final (off, on) = distractingRuleSets({
      ('deep work', 'com.example.chat'): Verdict.onTrack,
      ('admin', 'com.example.chat'): Verdict.offTrack,
      ('deep work', 'com.example.notes'): Verdict.onTrack,
      ('deep work', 'com.example.video'): Verdict.offTrack,
    });
    expect(off, {'com.example.chat', 'com.example.video'});
    expect(on, {'com.example.notes'});
  });
}
