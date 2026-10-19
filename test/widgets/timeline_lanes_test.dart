import 'package:drift_time/domain/models.dart';
import 'package:drift_time/painters/lane_painter.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:drift_time/widgets/timeline_lanes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _day = DateTime(2026, 10, 19);
DateTime _at(int h, int m, [int s = 0]) => DateTime(2026, 10, 19, h, m, s);

const _labels = {
  'com.example.notes': 'Notes',
  'com.example.chat': 'WhatsApp',
  'com.example.video': 'YouTube',
  'com.example.keyboard': 'Keyboard',
  'com.example.launcher': 'Launcher',
};

Segment _seg(
  String? p,
  DateTime start,
  DateTime end,
  Verdict v, {
  String? block = 'Work',
  int? id,
}) => Segment(p: p, start: start, end: end, verdict: v, blockName: block, sessionId: id);

/// [count] one-second slivers from [from], alternating two system-ish apps
/// and verdicts, back to back.
List<Segment> _slivers(DateTime from, int count, {String block = 'Work'}) => [
  for (var i = 0; i < count; i++)
    _seg(
      i.isEven ? 'com.example.keyboard' : 'com.example.launcher',
      from.add(Duration(seconds: i)),
      from.add(Duration(seconds: i + 1)),
      i.isEven ? Verdict.guessedOn : Verdict.guessedOff,
      block: block,
      id: 1000 + i,
    ),
];

/// A Work block from 09:00 to 11:00: idle, WhatsApp, Notes, 300 slivers,
/// YouTube, idle.
List<Segment> _busyMorning() => [
  _seg(null, _at(9, 0), _at(9, 10), Verdict.idle),
  _seg('com.example.chat', _at(9, 10), _at(9, 20), Verdict.guessedOff, id: 1),
  _seg('com.example.notes', _at(9, 20), _at(9, 50), Verdict.onTrack, id: 2),
  ..._slivers(_at(9, 50), 300),
  _seg('com.example.video', _at(9, 55), _at(10, 30), Verdict.offTrack, id: 3),
  _seg(null, _at(10, 30), _at(11, 0), Verdict.idle),
];

DayData _data(List<Segment> segments, {DateTime? now}) => DayData(
  day: _day,
  blocks: [ResolvedBlock(name: 'Work', start: _at(9, 0), end: _at(11, 0))],
  segments: segments,
  score: null,
  labels: _labels,
  now: now ?? _at(10, 0),
);

Widget _app(DayData data, {void Function(Segment)? onTap}) => MaterialApp(
  theme: buildDriftTheme(ThemeId.mono),
  home: Scaffold(body: TimelineLanes(data: data, onSegmentTap: onTap)),
);

void main() {
  group('drawnLanePieces', () {
    test('300 one-second slivers inside a block fold into the piece before', () {
      final pieces = drawnLanePieces(_busyMorning());
      expect(pieces.length, 5);
      final notes = pieces[2];
      expect(notes.p, 'com.example.notes');
      expect(notes.verdict, Verdict.onTrack);
      expect(notes.start, _at(9, 20));
      expect(notes.end, _at(9, 55), reason: 'the slivers draw as part of Notes');
      expect(notes.members.length, 301);
      expect(pieces[3].p, 'com.example.video');
      expect(pieces[3].start, _at(9, 55));
    });

    test('slivers at the start of a block fold into the next piece', () {
      final pieces = drawnLanePieces([
        ..._slivers(_at(9, 0), 60),
        _seg('com.example.notes', _at(9, 1), _at(9, 30), Verdict.onTrack, id: 2),
      ]);
      expect(pieces, hasLength(1));
      expect(pieces.single.start, _at(9, 0));
      expect(pieces.single.p, 'com.example.notes');
      expect(pieces.single.primary.sessionId, 2);
    });

    test('long same-app runs merge into one piece', () {
      final pieces = drawnLanePieces([
        _seg('com.example.notes', _at(9, 0), _at(9, 20), Verdict.onTrack, id: 1),
        _seg('com.example.notes', _at(9, 20), _at(9, 50), Verdict.onTrack, id: 2),
        _seg('com.example.notes', _at(9, 50), _at(10, 10), Verdict.onTrack, id: 3),
      ]);
      expect(pieces, hasLength(1));
      expect(pieces.single.start, _at(9, 0));
      expect(pieces.single.end, _at(10, 10));
      expect(pieces.single.primary.sessionId, 2, reason: 'the longest member');
    });

    test('pieces never merge across a block edge or a long gap', () {
      final pieces = drawnLanePieces([
        _seg(null, _at(8, 50), _at(9, 0), Verdict.idle, block: 'Gym'),
        _seg(null, _at(9, 0), _at(9, 10), Verdict.idle),
        _seg(null, _at(9, 10), _at(14, 0), Verdict.unplanned, block: null),
        _seg('com.example.video', _at(14, 0), _at(14, 10), Verdict.unplanned, block: null, id: 1),
        _seg('com.example.video', _at(14, 30), _at(14, 40), Verdict.unplanned, block: null, id: 2),
      ]);
      expect(pieces.map((p) => (p.start, p.end)), [
        (_at(8, 50), _at(9, 0)),
        (_at(9, 0), _at(9, 10)),
        (_at(14, 0), _at(14, 10)),
        (_at(14, 30), _at(14, 40)),
      ]);
    });

    test('the data is untouched', () {
      final segments = _busyMorning();
      final copy = List.of(segments);
      drawnLanePieces(segments);
      expect(segments, copy);
    });
  });

  group('TimelineLanes', () {
    testWidgets('each drawn piece has a semantics label', (tester) async {
      await tester.pumpWidget(_app(_data(_busyMorning())));
      expect(find.bySemanticsLabel('WhatsApp, Guessed off track'), findsOneWidget);
      expect(find.bySemanticsLabel('Notes, On track'), findsOneWidget);
      expect(find.bySemanticsLabel('YouTube, Off track'), findsOneWidget);
      expect(find.bySemanticsLabel('Idle, Idle'), findsNWidgets(2));
      expect(find.bySemanticsLabel(RegExp('^Keyboard')), findsNothing);
    });

    testWidgets('a tap at a y position opens the segment there', (tester) async {
      final tapped = <Segment>[];
      final data = _data(_busyMorning());
      await tester.pumpWidget(_app(data, onTap: tapped.add));
      final lane = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is LanePainter,
      );
      final top = tester.getTopLeft(lane);
      final x = tester.getCenter(lane).dx;
      // The view starts at 06:00 with 64 px per hour.
      double yAt(DateTime t) =>
          top.dy + (t.difference(_day).inSeconds / 3600 - 6) * 64;

      await tester.tapAt(Offset(x, yAt(_at(9, 15))));
      await tester.pump();
      expect(tapped, [data.segments[1]], reason: 'WhatsApp, 09:10 to 09:20');

      // Inside the slivers: the merged piece opens its longest member.
      await tester.tapAt(Offset(x, yAt(_at(9, 52))));
      await tester.pump();
      expect(tapped.last, data.segments[2]);
      expect(tapped.last.p, 'com.example.notes');

      // Over the plan block, outside the lane strip, nothing opens.
      final left = tester.getTopLeft(find.byType(TimelineLanes)).dx;
      await tester.tapAt(Offset(left + 60, yAt(_at(9, 15))));
      await tester.pump();
      expect(tapped, hasLength(2));
    });

    testWidgets('the widget count does not grow with segments', (tester) async {
      final segments = _busyMorning();
      await tester.pumpWidget(_app(_data(segments)));
      final widgets = find
          .descendant(
            of: find.byType(TimelineLanes),
            matching: find.byWidgetPredicate((_) => true),
            skipOffstage: false,
          )
          .evaluate()
          .length;
      final pieces = drawnLanePieces(segments).length;
      // Each drawn piece adds a Positioned, a Semantics and a MetaData.
      final rest = widgets - 3 * pieces;
      debugPrint(
        'TimelineLanes: $widgets widgets for ${segments.length} segments, '
        '$pieces pieces',
      );
      expect(segments.length, greaterThan(300));
      expect(rest, lessThan(60));
    });

    testWidgets('opens scrolled to an hour and a half before now', (tester) async {
      await tester.pumpWidget(_app(_data(_busyMorning(), now: _at(10, 0))));
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.pixels, (10 - 6) * 64 - 96);
    });
  });
}
