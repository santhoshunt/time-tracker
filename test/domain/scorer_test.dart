import 'package:drift_time/domain/classifier.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/domain/scorer.dart';
import 'package:flutter_test/flutter_test.dart';

const video = 'com.example.video';
const notes = 'com.example.notes';

DateTime at(int h, int m) => DateTime(2026, 10, 19, h, m);
final evening = DateTime(2026, 10, 19, 23);

const deep = 'Deep work';
final deepWork = ResolvedBlock(name: deep, start: at(9, 0), end: at(11, 0));

Segment seg(DateTime start, DateTime end, Verdict v, {String? block = deep, String? p}) =>
    Segment(p: p, start: start, end: end, verdict: v, blockName: block);

void main() {
  test('an all on-track day scores 100', () {
    final score = scoreDay([seg(at(9, 0), at(11, 0), Verdict.onTrack, p: notes)], [deepWork], evening);
    expect(score, const DayScore(plannedMin: 120, offMin: 0, idleMin: 0, noDataMin: 0, percent: 100));
  });

  test('an all off-track day scores 0', () {
    final score = scoreDay([seg(at(9, 0), at(11, 0), Verdict.offTrack, p: video)], [deepWork], evening);
    expect(score, const DayScore(plannedMin: 120, offMin: 120, idleMin: 0, noDataMin: 0, percent: 0));
  });

  test('guessedOff counts as off and guessedOn as on', () {
    final score = scoreDay([
      seg(at(9, 0), at(10, 0), Verdict.guessedOff, p: video),
      seg(at(10, 0), at(11, 0), Verdict.guessedOn, p: notes),
    ], [deepWork], evening);
    expect(score!.offMin, 60);
    expect(score.percent, 50);
  });

  test('idle inside a block counts as on track', () {
    final score = scoreDay([
      seg(at(9, 0), at(10, 30), Verdict.idle),
      seg(at(10, 30), at(11, 0), Verdict.offTrack, p: video),
    ], [deepWork], evening);
    expect(score, const DayScore(plannedMin: 120, offMin: 30, idleMin: 90, noDataMin: 0, percent: 75));
  });

  test('a no-data span leaves the denominator', () {
    final score = scoreDay([
      seg(at(9, 0), at(9, 30), Verdict.noData),
      seg(at(9, 30), at(10, 0), Verdict.offTrack, p: video),
      seg(at(10, 0), at(11, 0), Verdict.onTrack, p: notes),
    ], [deepWork], evening);
    // (120 - 30 - 30) / (120 - 30) = 66.7%
    expect(score, const DayScore(plannedMin: 120, offMin: 30, idleMin: 0, noDataMin: 30, percent: 67));
  });

  test('unplanned time outside blocks does not count', () {
    final score = scoreDay([
      seg(at(8, 0), at(9, 0), Verdict.unplanned, block: null, p: video),
      seg(at(9, 0), at(11, 0), Verdict.onTrack, p: notes),
      seg(at(11, 0), at(12, 0), Verdict.noData, block: null),
    ], [deepWork], evening);
    expect(score!.percent, 100);
    expect(score.noDataMin, 0);
  });

  test('today counts only planned time up to now', () {
    final block = ResolvedBlock(name: deep, start: at(9, 0), end: at(17, 0));
    final score = scoreDay([
      seg(at(9, 0), at(9, 30), Verdict.offTrack, p: video),
      seg(at(9, 30), at(10, 0), Verdict.onTrack, p: notes),
    ], [block], at(10, 0));
    expect(score, const DayScore(plannedMin: 60, offMin: 30, idleMin: 0, noDataMin: 0, percent: 50));
  });

  test('zero planned minutes gives no score, not 0 or 100', () {
    expect(scoreDay(const [], const [], evening), isNull);
    expect(scoreDay(const [], [deepWork], at(8, 0)), isNull, reason: 'before the first block');
  });

  test('a block that is all no data gives no score', () {
    expect(scoreDay([seg(at(9, 0), at(11, 0), Verdict.noData)], [deepWork], evening), isNull);
  });

  test('overlapping blocks count their union once', () {
    final blocks = [
      deepWork,
      ResolvedBlock(name: 'Calls', start: at(10, 0), end: at(12, 0)),
    ];
    final score = scoreDay([
      seg(at(9, 0), at(10, 0), Verdict.onTrack, p: notes),
      seg(at(10, 0), at(12, 0), Verdict.offTrack, block: 'Calls', p: video),
    ], blocks, evening);
    expect(score!.plannedMin, 180);
    expect(score.percent, 33);
  });

  test('end to end with the classifier', () {
    final day = DateTime(2026, 10, 19);
    final segments = splitAndClassify(
      day: day,
      blocks: [deepWork],
      sessions: [
        Session(id: 1, p: video, start: at(9, 0), end: at(9, 30)),
        Session(id: 2, p: notes, start: at(9, 30), end: at(10, 30)),
      ],
      idle: [IdleSpan(at(10, 30), at(11, 0), IdleKind.locked)],
      gaps: const [],
      rules: const {},
      overrides: const {},
      categories: const {video: 'video', notes: 'productivity'},
      now: evening,
    );
    expect(scoreDay(segments, [deepWork], evening),
        const DayScore(plannedMin: 120, offMin: 30, idleMin: 30, noDataMin: 0, percent: 75));
  });
}
