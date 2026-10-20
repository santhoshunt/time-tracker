import 'package:drift_time/domain/app_groups.dart';
import 'package:drift_time/domain/classifier.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/domain/nudge_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

final _day = DateTime(2026, 10, 20);
DateTime _at(int h, int m) => DateTime(2026, 10, 20, h, m);

const _work = AppGroup(
  id: 1,
  name: 'Work apps',
  emoji: 'w',
  colorIdx: 0,
  kind: GroupKind.productive,
  apps: {'com.example.chat', 'com.example.notes'},
);
const _sinks = AppGroup(
  id: 2,
  name: 'Time sinks',
  emoji: 's',
  colorIdx: 4,
  kind: GroupKind.distracting,
  apps: {'com.example.video', 'com.example.chat'},
);

const _categories = {
  'com.example.chat': 'social',
  'com.example.notes': 'productivity',
  'com.example.video': 'video',
  'com.example.tool': 'productivity',
};

/// The verdict of a 10-minute session of [p] at 09:00 in [block].
Verdict _judge(
  String p, {
  ResolvedBlock? block,
  Map<(String, String), Verdict> rules = const {},
  AppGroups groups = AppGroups.none,
}) {
  final b = block ?? ResolvedBlock(name: 'Deep work', start: _at(9, 0), end: _at(12, 0));
  final segments = classifyFrame(
    dayStart: _day,
    dayEnd: DateTime(2026, 10, 21),
    blocks: [b],
    sessions: [Session(id: 1, p: p, start: _at(9, 0), end: _at(9, 10))],
    idle: const [],
    gaps: const [],
    rules: rules,
    overrides: const {},
    categories: _categories,
    now: _at(9, 30),
    groups: groups,
  );
  return segments.firstWhere((s) => s.p == p).verdict;
}

void main() {
  group('the classifier order', () {
    test('a group the block allows makes a social app on track', () {
      final g = AppGroups(groups: const [_work], byBlock: {
        'deep work': {1: Verdict.onTrack},
      });
      expect(_judge('com.example.chat'), Verdict.guessedOff);
      expect(_judge('com.example.chat', groups: g), Verdict.onTrack);
    });

    test("an app's own rule beats the block's group", () {
      final g = AppGroups(groups: const [_work], byBlock: {
        'deep work': {1: Verdict.onTrack},
      });
      expect(
        _judge('com.example.chat', groups: g, rules: {('deep work', 'com.example.chat'): Verdict.offTrack}),
        Verdict.offTrack,
      );
    });

    test('between two groups a block uses, off track wins', () {
      final g = AppGroups(groups: const [_work, _sinks], byBlock: {
        'deep work': {1: Verdict.onTrack, 2: Verdict.offTrack},
      });
      expect(_judge('com.example.chat', groups: g), Verdict.offTrack);
      expect(_judge('com.example.notes', groups: g), Verdict.onTrack);
    });

    test('a Distracting group is off track in a block that set nothing', () {
      const g = AppGroups(groups: [_sinks]);
      expect(_judge('com.example.video', groups: g), Verdict.offTrack);
    });

    test('"any app" beats a Distracting group', () {
      const g = AppGroups(groups: [_sinks]);
      final lunch = ResolvedBlock(name: 'Lunch', start: _at(9, 0), end: _at(12, 0), anyApp: true);
      expect(_judge('com.example.video', groups: g, block: lunch), Verdict.onTrack);
    });

    test('a block can allow a Distracting group', () {
      final g = AppGroups(groups: const [_sinks], byBlock: {
        'deep work': {2: Verdict.onTrack},
      });
      expect(_judge('com.example.video', groups: g), Verdict.onTrack);
    });

    test('a Productive group alone leaves the guess, so Drift still asks', () {
      const g = AppGroups(groups: [_work]);
      expect(_judge('com.example.chat', groups: g), Verdict.guessedOff);
      expect(_judge('com.example.notes', groups: g), Verdict.guessedOn);
    });

    test('no groups classify as before', () {
      expect(_judge('com.example.video'), Verdict.guessedOff);
      expect(_judge('com.example.tool'), Verdict.guessedOn);
    });
  });

  group('nudge windows', () {
    final blocks = [
      ResolvedBlock(name: 'Deep work', start: _at(9, 0), end: _at(12, 0)),
      ResolvedBlock(name: 'Study', start: _at(13, 0), end: _at(14, 0)),
    ];

    test('a Distracting group joins every window\'s off set unless allowed', () {
      final g = AppGroups(groups: const [_sinks], byBlock: {
        'study': {2: Verdict.onTrack},
      });
      final w = nudgeWindows(blocks: blocks, rules: const {}, now: _at(8, 0), groups: g);
      expect(w[0].off, {'com.example.video', 'com.example.chat'});
      expect(w[1].off, isEmpty);
      expect(w[1].on, {'com.example.video', 'com.example.chat'});
    });

    test('an app rule beats the group in the window too', () {
      final g = AppGroups(groups: const [_work], byBlock: {
        'deep work': {1: Verdict.onTrack},
      });
      final w = nudgeWindows(
        blocks: blocks,
        rules: {('deep work', 'com.example.chat'): Verdict.offTrack},
        now: _at(8, 0),
        groups: g,
      );
      expect(w[0].on, {'com.example.notes'});
      expect(w[0].off, {'com.example.chat'});
    });
  });

  test('distracting sets: Distracting groups count, Productive ones never, rules first', () {
    const g = AppGroups(groups: [_work, _sinks]);
    final (off, on) = distractingRuleSets({('admin', 'com.example.tool'): Verdict.offTrack}, g);
    expect(off, {'com.example.video', 'com.example.chat', 'com.example.tool'});
    // Chat is in both kinds: Distracting wins.
    expect(on, {'com.example.notes'});
  });

  test('blockVerdict and forBlock', () {
    final g = AppGroups(groups: const [_work, _sinks], byBlock: {
      'deep work': {1: Verdict.onTrack, 2: Verdict.offTrack},
    });
    expect(g.blockVerdict('deep work', 'com.example.notes'), Verdict.onTrack);
    expect(g.blockVerdict('deep work', 'com.example.tool'), isNull);
    expect(g.blockVerdict('lunch', 'com.example.notes'), isNull);
    expect(g.forBlock('deep work', Verdict.onTrack), {1});
    expect(g.forBlock('deep work', Verdict.offTrack), {2});
  });
}
