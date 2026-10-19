import 'package:drift_time/domain/classifier.dart';
import 'package:drift_time/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

const video = 'com.example.video';
const chat = 'com.example.chat';
const notes = 'com.example.notes';

final day = DateTime(2026, 10, 19);
DateTime at(int h, int m) => DateTime(2026, 10, 19, h, m);
final endOfDay = DateTime(2026, 10, 20);

const categories = {video: 'video', chat: 'social', notes: 'productivity'};

ResolvedBlock block(String name, DateTime start, DateTime end, {bool anyApp = false}) =>
    ResolvedBlock(name: name, start: start, end: end, anyApp: anyApp);

List<Segment> classify({
  List<ResolvedBlock> blocks = const [],
  List<Session> sessions = const [],
  List<IdleSpan> idle = const [],
  List<GapSpan> gaps = const [],
  Map<(String, String), Verdict> rules = const {},
  Map<int, Verdict> overrides = const {},
  DateTime? now,
  DateTime? forDay,
}) =>
    splitAndClassify(
      day: forDay ?? day,
      blocks: blocks,
      sessions: sessions,
      idle: idle,
      gaps: gaps,
      rules: rules,
      overrides: overrides,
      categories: categories,
      now: now ?? DateTime(2026, 10, 21),
    );

/// The segments inside [from, to).
List<Segment> within(List<Segment> segs, DateTime from, DateTime to) =>
    [for (final s in segs) if (!s.start.isBefore(from) && !s.end.isAfter(to)) s];

/// Every segment list must tile its window with no holes or overlaps.
void expectTiled(List<Segment> segs, DateTime from, DateTime to) {
  expect(segs, isNotEmpty);
  expect(segs.first.start, from);
  expect(segs.last.end, to);
  for (var i = 1; i < segs.length; i++) {
    expect(segs[i].start, segs[i - 1].end, reason: 'hole or overlap at $i');
  }
}

void main() {
  final deepWork = block('Deep work', at(9, 0), at(11, 0));
  final videoSession = Session(id: 1, p: video, start: at(9, 0), end: at(9, 30));

  Verdict verdictOf(List<Segment> segs) =>
      segs.firstWhere((s) => s.sessionId == 1).verdict;

  group('precedence', () {
    test('category guess: video guesses off, productivity guesses on, '
        'an unknown category counts as undefined and guesses on', () {
      final segs = classify(blocks: [deepWork], sessions: [
        videoSession,
        Session(id: 2, p: notes, start: at(9, 30), end: at(10, 0)),
        Session(id: 3, p: 'com.example.unknown', start: at(10, 0), end: at(10, 30)),
      ]);
      Verdict of(int id) => segs.firstWhere((s) => s.sessionId == id).verdict;
      expect(of(1), Verdict.guessedOff);
      expect(of(2), Verdict.guessedOn);
      expect(of(3), Verdict.guessedOn);
    });

    test('anyApp beats the category guess', () {
      final segs = classify(
        blocks: [block('Deep work', at(9, 0), at(11, 0), anyApp: true)],
        sessions: [videoSession],
      );
      expect(verdictOf(segs), Verdict.onTrack);
    });

    test('a rule beats anyApp, matched by block key', () {
      final segs = classify(
        blocks: [block('Deep Work ', at(9, 0), at(11, 0), anyApp: true)],
        sessions: [videoSession],
        rules: {('deep work', video): Verdict.offTrack},
      );
      expect(verdictOf(segs), Verdict.offTrack);
    });

    test('a rule beats the category guess', () {
      final segs = classify(
        blocks: [deepWork],
        sessions: [videoSession],
        rules: {('deep work', video): Verdict.onTrack},
      );
      expect(verdictOf(segs), Verdict.onTrack);
    });

    test('a session override beats a rule', () {
      final segs = classify(
        blocks: [deepWork],
        sessions: [videoSession],
        rules: {('deep work', video): Verdict.offTrack},
        overrides: {1: Verdict.onTrack},
      );
      expect(verdictOf(segs), Verdict.onTrack);
    });

    test('a rule for another block does not apply', () {
      final segs = classify(
        blocks: [deepWork],
        sessions: [videoSession],
        rules: {('evening', video): Verdict.onTrack},
      );
      expect(verdictOf(segs), Verdict.guessedOff);
    });
  });

  test('a session spanning two blocks is cut at the edge and judged per block', () {
    final segs = classify(
      blocks: [block('Deep work', at(9, 0), at(10, 0)), block('Admin', at(10, 0), at(11, 0))],
      sessions: [Session(id: 5, p: notes, start: at(9, 30), end: at(10, 30))],
      rules: {('admin', notes): Verdict.offTrack},
    );
    final notesSegs = [for (final s in segs) if (s.sessionId == 5) s];
    expect(notesSegs, [
      Segment(p: notes, start: at(9, 30), end: at(10, 0), verdict: Verdict.guessedOn, blockName: 'Deep work', sessionId: 5),
      Segment(p: notes, start: at(10, 0), end: at(10, 30), verdict: Verdict.offTrack, blockName: 'Admin', sessionId: 5),
    ]);
  });

  test('a session crossing midnight is cut at midnight on both days', () {
    final crossing = Session(id: 9, p: video, start: DateTime(2026, 10, 18, 23, 30), end: at(0, 30));
    final yesterday = classify(forDay: DateTime(2026, 10, 18), sessions: [crossing]);
    final today = classify(sessions: [crossing]);
    expect(yesterday.last,
        Segment(p: video, start: DateTime(2026, 10, 18, 23, 30), end: day, verdict: Verdict.unplanned, sessionId: 9));
    expect(today.first, Segment(p: video, start: day, end: at(0, 30), verdict: Verdict.unplanned, sessionId: 9));
    expectTiled(yesterday, DateTime(2026, 10, 18), day);
    expectTiled(today, day, endOfDay);
  });

  test('a session outside every block is unplanned', () {
    final segs = classify(
      blocks: [deepWork],
      sessions: [Session(id: 4, p: chat, start: at(12, 0), end: at(12, 20))],
    );
    expect(segs.where((s) => s.sessionId == 4).single,
        Segment(p: chat, start: at(12, 0), end: at(12, 20), verdict: Verdict.unplanned, sessionId: 4));
    expect(segs.where((s) => s.blockName == null).every((s) => s.verdict == Verdict.unplanned), isTrue);
  });

  test('idle inside a block is idle, and so is block time with no session at all', () {
    final segs = classify(
      blocks: [deepWork],
      sessions: [Session(id: 1, p: notes, start: at(9, 0), end: at(9, 20))],
      idle: [IdleSpan(at(9, 20), at(10, 0), IdleKind.screenOff)],
    );
    expect(within(segs, at(9, 0), at(11, 0)), [
      Segment(p: notes, start: at(9, 0), end: at(9, 20), verdict: Verdict.guessedOn, blockName: 'Deep work', sessionId: 1),
      Segment(start: at(9, 20), end: at(11, 0), verdict: Verdict.idle, blockName: 'Deep work'),
    ]);
  });

  test('gap time is no data and wins over a session', () {
    final segs = classify(
      blocks: [deepWork],
      sessions: [Session(id: 1, p: video, start: at(9, 0), end: at(10, 0))],
      gaps: [GapSpan(at(9, 30), at(13, 0))],
    );
    expect(within(segs, at(9, 0), at(13, 0)), [
      Segment(p: video, start: at(9, 0), end: at(9, 30), verdict: Verdict.guessedOff, blockName: 'Deep work', sessionId: 1),
      Segment(start: at(9, 30), end: at(11, 0), verdict: Verdict.noData, blockName: 'Deep work'),
      Segment(start: at(11, 0), end: at(13, 0), verdict: Verdict.noData),
    ]);
  });

  test('only time up to now is returned, and an open session is cut at now', () {
    final segs = classify(
      blocks: [deepWork],
      sessions: [Session(id: 1, p: video, start: at(9, 0), end: at(10, 30))],
      now: at(9, 45),
    );
    expectTiled(segs, day, at(9, 45));
    expect(segs.last.verdict, Verdict.guessedOff);
  });

  test('a day that has not started yet gives no segments', () {
    expect(classify(blocks: [deepWork], now: DateTime(2026, 10, 18, 12)), isEmpty);
  });

  test('where blocks overlap, the block that started last owns the time', () {
    final segs = classify(
      blocks: [block('Deep work', at(9, 0), at(12, 0)), block('Calls', at(10, 0), at(11, 0), anyApp: true)],
      sessions: [Session(id: 1, p: video, start: at(9, 30), end: at(11, 30))],
    );
    expect(within(segs, at(9, 30), at(11, 30)).map((s) => (s.blockName, s.verdict)), [
      ('Deep work', Verdict.guessedOff),
      ('Calls', Verdict.onTrack),
      ('Deep work', Verdict.guessedOff),
    ]);
  });

  test('a whole past day is tiled from midnight to midnight', () {
    final segs = classify(
      blocks: [deepWork],
      sessions: [Session(id: 1, p: video, start: at(9, 15), end: at(9, 45))],
      idle: [IdleSpan(at(1, 0), at(7, 0), IdleKind.screenOff)],
    );
    expectTiled(segs, day, endOfDay);
  });

  // The test machine runs in IST, which has no daylight-saving changes, so
  // these cases call classifyFrame with hand-built UTC day bounds 23 and 25
  // hours apart. splitAndClassify passes the local midnights the same way.
  group('daylight-saving days through explicit day bounds', () {
    final start = DateTime.utc(2026, 3, 29);

    List<Segment> frame(Duration length) {
      final end = start.add(length);
      return classifyFrame(
        dayStart: start,
        dayEnd: end,
        blocks: [ResolvedBlock(name: 'All day', start: start, end: end)],
        sessions: [
          Session(id: 1, p: video, start: start.add(const Duration(hours: 1)), end: start.add(const Duration(hours: 2))),
        ],
        idle: const [],
        gaps: const [],
        rules: const {},
        overrides: const {},
        categories: categories,
        now: start.add(const Duration(days: 2)),
      );
    }

    Duration total(List<Segment> segs) => segs.fold(Duration.zero, (sum, s) => sum + s.duration);

    test('a 23-hour day gives 23 hours of segments', () {
      final segs = frame(const Duration(hours: 23));
      expect(total(segs), const Duration(hours: 23));
      expect(segs.last.end, start.add(const Duration(hours: 23)));
    });

    test('a 25-hour day gives 25 hours of segments', () {
      final segs = frame(const Duration(hours: 25));
      expect(total(segs), const Duration(hours: 25));
      expect(segs.where((s) => s.verdict == Verdict.guessedOff).single.duration, const Duration(hours: 1));
    });
  });
}
