import 'package:drift_time/domain/app_groups.dart';
import 'package:drift_time/domain/classifier.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/domain/nudge_snapshot.dart';
import 'package:drift_time/domain/scorer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

final _day = DateTime(2026, 10, 20);
DateTime _at(int h, int m) => DateTime(2026, 10, 20, h, m);

final _lunch = ResolvedBlock(name: 'Lunch', start: _at(13, 0), end: _at(14, 0));
final _work = ResolvedBlock(name: 'Work', start: _at(9, 0), end: _at(12, 0));

/// Instagram for 30 minutes in Lunch, with [rules].
List<Segment> _lunchSegments(Map<(String, String), Verdict> rules) => classifyFrame(
  dayStart: _day,
  dayEnd: DateTime(2026, 10, 21),
  blocks: [_lunch],
  sessions: [Session(id: 1, p: 'com.example.social', start: _at(13, 0), end: _at(13, 30))],
  idle: const [],
  gaps: const [],
  rules: rules,
  overrides: const {},
  categories: const {'com.example.social': 'social'},
  now: _at(14, 0),
);

/// Neutral: fine in the block it was given for, and nowhere else.
void main() {
  const neutralInLunch = {('lunch', 'com.example.social'): Verdict.neutral};

  test('a neutral rule classifies as neutral and scores like on track', () {
    final neutral = _lunchSegments(neutralInLunch);
    expect(neutral.firstWhere((s) => s.p == 'com.example.social').verdict, Verdict.neutral);
    final on = _lunchSegments(const {('lunch', 'com.example.social'): Verdict.onTrack});
    expect(scoreDay(neutral, [_lunch], _at(14, 0)), scoreDay(on, [_lunch], _at(14, 0)));
    expect(scoreDay(neutral, [_lunch], _at(14, 0))!.percent, 100);
  });

  test('a neutral rule beats a Distracting group in its block', () {
    const sinks = AppGroup(
      id: 1,
      name: 'Time sinks',
      emoji: 's',
      colorIdx: 0,
      kind: GroupKind.distracting,
      apps: {'com.example.social'},
    );
    final segments = classifyFrame(
      dayStart: _day,
      dayEnd: DateTime(2026, 10, 21),
      blocks: [_lunch],
      sessions: [Session(id: 1, p: 'com.example.social', start: _at(13, 0), end: _at(13, 30))],
      idle: const [],
      gaps: const [],
      rules: neutralInLunch,
      overrides: const {},
      categories: const {'com.example.social': 'social'},
      now: _at(14, 0),
      groups: const AppGroups(groups: [sinks]),
    );
    expect(segments.firstWhere((s) => s.p == 'com.example.social').verdict, Verdict.neutral);
  });

  test('neutral in Lunch stops nudges in Lunch only', () {
    final w = nudgeWindows(blocks: [_work, _lunch], rules: neutralInLunch, now: _at(8, 0));
    final work = w.firstWhere((x) => x.block == 'Work');
    final lunch = w.firstWhere((x) => x.block == 'Lunch');
    expect(lunch.on, contains('com.example.social'));
    expect(lunch.off, isNot(contains('com.example.social')));
    expect(work.on, isNot(contains('com.example.social')));
  });

  test("neutral in Lunch leaves Instagram distracting for the day's total", () {
    // An on-track rule takes an app out of the day's distracting time; a
    // neutral one must not, so the social guess still counts it.
    final (off, on) = distractingRuleSets(neutralInLunch);
    expect(on, isNot(contains('com.example.social')));
    expect(off, isNot(contains('com.example.social')));
    final (_, onWithRule) = distractingRuleSets(const {('lunch', 'com.example.social'): Verdict.onTrack});
    expect(onWithRule, contains('com.example.social'));
  });

  test('neutral rules and overrides are stored and read back', () async {
    final s = await testServices();
    addTearDown(s.db.close);
    await s.rules.upsertRule('Lunch', 'com.example.social', Verdict.neutral, testNow);
    expect((await s.rules.allRules())[('lunch', 'com.example.social')], Verdict.neutral);
    await s.rules.setOverride(7, Verdict.neutral);
    expect((await s.rules.allOverrides())[7], Verdict.neutral);
  });
}
