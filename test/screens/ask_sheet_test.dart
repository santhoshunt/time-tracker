import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/services/day_loader.dart';
import 'package:drift_time/widgets/ask_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/seed.dart';
import '../helpers/test_app.dart';

DateTime _at(int h, int m) => DateTime(2026, 10, 19, h, m);

/// The sample day's sessions, as [seedSampleDay] stores them.
List<Session> _sampleSessions() => [
  Session(p: 'com.example.music', start: _at(8, 10), end: _at(8, 50)),
  Session(p: 'com.example.notes', start: _at(9, 5), end: _at(9, 35)),
  Session(p: 'com.example.social', start: _at(9, 40), end: _at(10, 5)),
  Session(p: 'com.example.chat', start: _at(10, 15), end: _at(10, 24)),
  Session(p: 'com.example.notes', start: _at(10, 30), end: _at(11, 10)),
  Session(p: 'com.example.video', start: _at(11, 15), end: _at(11, 50)),
  Session(p: 'com.example.video', start: _at(12, 10), end: _at(12, 40)),
  Session(p: 'com.example.meet', start: _at(13, 5), end: _at(13, 25)),
];

/// Replaces the sample day's sessions with [sessions].
Future<void> _replaceSessions(AppServices s, List<Session> sessions) =>
    s.sessions.replaceDay(_at(0, 0), DateTime(2026, 10, 20), sessions, [
      IdleSpan(_at(7, 0), _at(8, 10), IdleKind.screenOff),
      IdleSpan(_at(11, 50), _at(12, 10), IdleKind.locked),
    ]);

/// Session ids of [p] on the test day, in start order.
Future<List<int>> _idsOf(AppServices s, String p) async {
  final all = await s.sessions.sessionsBetween(_at(0, 0), DateTime(2026, 10, 20));
  return [
    for (final x in all)
      if (x.p == p) x.id!,
  ];
}

void main() {
  late AppServices s;
  late SettingsProvider settings;

  setUp(() async {
    s = await testServices();
    settings = await testSettings();
    await seedSampleDay(s, testNow);
  });

  tearDown(() => s.db.close());

  /// Pumps a page with an "Ask" button that starts the queue for [day];
  /// returns a getter for the queue's result once it finishes.
  Future<Future<int>? Function()> pumpQueue(WidgetTester tester, DayData day) async {
    Future<int>? result;
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(393, 851) * 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      withApp(
        s,
        settings,
        Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => result = showAskQueue(ctx, s, day),
                child: const Text('Ask'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    return () => result;
  }

  Future<void> tapAnswer(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(OutlinedButton, label));
    await tester.pumpAndSettle();
  }

  testWidgets('asks oldest first and returns how many were answered', (tester) async {
    final day = await loadDay(s, testNow);
    final result = await pumpQueue(tester, day);

    expect(find.text('Spotify during Gym?'), findsOneWidget);
    expect(find.text('Used 08:10 to 08:50'), findsOneWidget);
    await tapAnswer(tester, 'On track');

    expect(find.text('Spotify during Gym?'), findsNothing);
    expect(find.text('WhatsApp during Deep work?'), findsOneWidget);
    expect(find.text('Used 10:15 to 10:24'), findsOneWidget);
    expect(find.text('Remember for every Deep work'), findsOneWidget);
    await tapAnswer(tester, 'Off track');

    expect(find.byType(AskSheet), findsNothing);
    expect(await result(), 2);
  });

  testWidgets('remember writes a rule for the block', (tester) async {
    final day = await loadDay(s, testNow);
    var bumps = 0;
    s.revision.addListener(() => bumps++);
    await pumpQueue(tester, day);

    await tapAnswer(tester, 'Off track');

    final rules = await s.rules.allRules();
    expect(rules[('gym', 'com.example.music')], Verdict.offTrack);
    expect(await s.rules.allOverrides(), isEmpty);
    expect(bumps, 1);
  });

  testWidgets('unchecked writes overrides for every matching session and no rule', (tester) async {
    await _replaceSessions(s, [
      ..._sampleSessions(),
      // A second WhatsApp session in Deep work, and one in Meetings.
      Session(p: 'com.example.chat', start: _at(9, 36), end: _at(9, 39)),
      Session(p: 'com.example.chat', start: _at(13, 26), end: _at(13, 29)),
    ]);
    // Settle Gym first, so WhatsApp in Deep work is asked first.
    await s.rules.upsertRule('Gym', 'com.example.music', Verdict.onTrack, testNow);
    final day = await loadDay(s, testNow);
    final result = await pumpQueue(tester, day);

    expect(find.text('WhatsApp during Deep work?'), findsOneWidget);
    expect(find.text('Used 09:36 to 09:39'), findsOneWidget);
    await tester.tap(find.text('Remember for every Deep work'));
    await tester.pumpAndSettle();
    await tapAnswer(tester, 'On track');

    // The Meetings question comes next; closing it stops the queue.
    expect(find.text('WhatsApp during Meetings?'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(await result(), 1);

    final ids = await _idsOf(s, 'com.example.chat');
    expect(ids, hasLength(3));
    final overrides = await s.rules.allOverrides();
    expect(overrides, {ids[0]: Verdict.onTrack, ids[1]: Verdict.onTrack});
    final rules = await s.rules.allRules();
    expect(rules.containsKey(('deep work', 'com.example.chat')), isFalse);
  });

  testWidgets('closing the first sheet stops the queue', (tester) async {
    final day = await loadDay(s, testNow);
    final rulesBefore = await s.rules.allRules();
    final result = await pumpQueue(tester, day);

    expect(find.text('Spotify during Gym?'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.byType(AskSheet), findsNothing);
    expect(find.text('WhatsApp during Deep work?'), findsNothing);
    expect(await result(), 0);
    expect(await s.rules.allRules(), rulesBefore);
    expect(await s.rules.allOverrides(), isEmpty);
  });

  testWidgets('the guess line names the category', (tester) async {
    await s.rules.upsertRule('Gym', 'com.example.music', Verdict.onTrack, testNow);
    final day = await loadDay(s, testNow);
    await pumpQueue(tester, day);

    expect(find.text('Guess: off track. Android lists it as social.'), findsOneWidget);
  });

  testWidgets('the guess line for an app with no category', (tester) async {
    await s.apps.upsertAll(const [
      AppInfo(p: 'com.example.mystery', label: 'Mystery', category: 'undefined'),
    ], testNow);
    await _replaceSessions(s, [
      Session(p: 'com.example.mystery', start: _at(8, 15), end: _at(8, 30)),
    ]);
    final day = await loadDay(s, testNow);
    await pumpQueue(tester, day);

    expect(find.text('Mystery during Gym?'), findsOneWidget);
    expect(
      find.text("Guess: on track. Android doesn't say what kind of app it is."),
      findsOneWidget,
    );
  });

  test('guess words for every category', () {
    expect(guessLine(Verdict.guessedOn, 'audio'), 'Guess: on track. Android lists it as music.');
    expect(guessLine(Verdict.guessedOn, 'image'), 'Guess: on track. Android lists it as photos.');
    expect(guessLine(Verdict.guessedOff, 'game'), 'Guess: off track. Android lists it as game.');
    expect(categoryWord('something new'), "doesn't say");
  });
}
