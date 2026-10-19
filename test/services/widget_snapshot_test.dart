import 'dart:convert';
import 'dart:io';

import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:drift_time/services/widget_snapshot.dart';
import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_background_channels.dart';
import '../helpers/seed.dart';
import '../helpers/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppServices s;
  late SettingsProvider settings;
  late FakeBackgroundChannels channels;
  late Directory dir;

  setUp(() async {
    s = await testServices();
    settings = await testSettings(theme: ThemeId.blackCyan);
    channels = FakeBackgroundChannels();
    dir = await Directory.systemTemp.createTemp('drift_widgets');
  });

  tearDown(() async {
    channels.dispose();
    await s.db.close();
    await dir.delete(recursive: true);
  });

  test('the snapshot has the contract shape', () async {
    await seedSampleDay(s, testNow);
    final day = await loadDay(s, testNow);
    final snap = buildWidgetSnapshot(day, DriftColors.of(ThemeId.mono));

    expect(snap.keys, unorderedEquals([
      'v', 'computedAtMs', 'dayStartMs', 'blocks', 'pieces',
      'percent', 'driftMin', 'plannedMin', 'colors',
    ]));
    expect(snap['v'], 1);
    expect(snap['computedAtMs'], testNow.millisecondsSinceEpoch);
    expect(snap['dayStartMs'], DateTime(2026, 10, 19).millisecondsSinceEpoch);
    expect(snap['percent'], day.score!.percent);
    expect(snap['driftMin'], day.score!.offMin);
    expect(snap['plannedMin'], day.score!.plannedMin);

    final blocks = snap['blocks'] as List;
    expect(blocks.map((b) => (b as Map)['name']), ['Gym', 'Deep work', 'Lunch', 'Meetings', 'Family']);
    expect(blocks.first, {
      'name': 'Gym',
      'startMs': DateTime(2026, 10, 19, 8).millisecondsSinceEpoch,
      'endMs': DateTime(2026, 10, 19, 9).millisecondsSinceEpoch,
    });
    // It must survive a JSON round trip unchanged, as Kotlin reads JSON.
    expect(jsonDecode(jsonEncode(snap)), snap);
  });

  test('pieces are the Today lane pieces, merged and with verdict names', () {
    final d = DateTime(2026, 10, 19);
    DateTime at(int h, int m) => DateTime(2026, 10, 19, h, m);
    Segment seg(int h1, int m1, int h2, int m2, Verdict v, [String? p = 'com.example.video']) =>
        Segment(p: p, start: at(h1, m1), end: at(h2, m2), verdict: v, blockName: 'Deep work');
    final day = DayData(
      day: d,
      blocks: [ResolvedBlock(name: 'Deep work', start: at(9, 0), end: at(12, 0))],
      segments: [
        // Two neighbours with the same app and verdict merge into one.
        seg(9, 0, 9, 20, Verdict.offTrack),
        seg(9, 20, 9, 40, Verdict.offTrack),
        // A 1-minute blip folds into the piece before it.
        seg(9, 40, 9, 41, Verdict.onTrack, 'com.example.notes'),
        seg(10, 0, 10, 30, Verdict.onTrack, 'com.example.notes'),
        // Unplanned idle time is not drawn.
        Segment(start: at(12, 0), end: at(13, 0), verdict: Verdict.unplanned),
      ],
      score: const DayScore(plannedMin: 90, offMin: 40, idleMin: 0, noDataMin: 0, percent: 56),
      labels: const {},
      now: at(10, 30),
    );
    final pieces = buildWidgetSnapshot(day, DriftColors.of(ThemeId.mono))['pieces'] as List;
    expect(pieces, [
      {'startMs': at(9, 0).millisecondsSinceEpoch, 'endMs': at(9, 41).millisecondsSinceEpoch, 'verdict': 'offTrack'},
      {'startMs': at(10, 0).millisecondsSinceEpoch, 'endMs': at(10, 30).millisecondsSinceEpoch, 'verdict': 'onTrack'},
    ]);
  });

  test('colours are #RRGGBB strings from the theme', () async {
    final day = await loadDay(s, testNow);
    final colors = buildWidgetSnapshot(day, DriftColors.of(ThemeId.cleanLight))['colors'] as Map;
    expect(colors, {
      'bg': '#F7F8FA',
      'card': '#FFFFFF',
      'line': '#E3E7ED',
      'text': '#1B1F24',
      'textSecondary': '#5F6B7A',
      'accent': '#4A90E2',
      'onTrack': '#2E9E6B',
      'offTrack': '#E0504E',
      'guessed': '#F2B544',
    });
  });

  test('a day with nothing planned has no score and zero minutes', () async {
    final day = await loadDay(s, testNow);
    final snap = buildWidgetSnapshot(day, DriftColors.of(ThemeId.mono));
    expect(snap['percent'], isNull);
    expect((snap['driftMin'], snap['plannedMin']), (0, 0));
    expect(snap['blocks'], isEmpty);
  });

  test('write puts the file in place, in the chosen theme, then asks for a redraw', () async {
    await seedSampleDay(s, testNow);
    final ok = await writeWidgetSnapshot(s, settings, directory: () async => dir, bridge: channels.bridge);
    expect(ok, isTrue);

    final file = File('${dir.path}/$widgetSnapshotFile');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(json['v'], 1);
    expect((json['colors'] as Map)['accent'], '#38BDF8');
    expect(File('${file.path}.tmp').existsSync(), isFalse);
    expect(channels.of('refresh'), hasLength(1));
  });

  test('a failed write keeps the old file and asks for no redraw', () async {
    final ok = await writeWidgetSnapshot(
      s,
      settings,
      directory: () async => Directory('${dir.path}/missing/deeper'),
      bridge: channels.bridge,
    );
    expect(ok, isFalse);
    expect(channels.of('refresh'), isEmpty);
  });
}
