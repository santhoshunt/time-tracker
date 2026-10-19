import 'package:drift_time/domain/models.dart';
import 'package:drift_time/domain/sessionizer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_usage_source.dart';

const video = 'com.example.video';
const chat = 'com.example.chat';
const notes = 'com.example.notes';
const launcher = 'com.example.launcher';
const drift = 'io.github.santhoshunt.drift';
const systemUi = 'com.android.systemui';
const idlePackages = {launcher, drift, systemUi};

DateTime at(int h, int m, [int s = 0, int ms = 0]) => DateTime(2026, 10, 19, h, m, s, ms);

List<RawEvent> fixture(String name) => [for (final m in loadEventFixture(name)) RawEvent.fromMap(m)!];

RawEvent ev(DateTime t, String p, String? c, EventKind k) =>
    RawEvent(t.millisecondsSinceEpoch, p, c, k);

SessionizeResult run(List<RawEvent> events, {DateTime? now}) =>
    buildSessions(events, idlePackages: idlePackages, now: now ?? at(23, 59));

Session s(String p, DateTime start, DateTime end) => Session(p: p, start: start, end: end);

void main() {
  test('one app resumed then paused (fixture one_app)', () {
    final r = run(fixture('one_app'));
    expect(r.sessions, [s(video, at(9, 0), at(9, 30))]);
    expect(r.idle, isEmpty);
  });

  test('unsorted input gives the same result (fixture one_app reversed)', () {
    final r = run(fixture('one_app').reversed.toList());
    expect(r.sessions, [s(video, at(9, 0), at(9, 30))]);
  });

  test('two activities with an overlapping resume and pause stay one session '
      '(fixture two_activities_overlap)', () {
    final r = run(fixture('two_activities_overlap'));
    expect(r.sessions, [s(notes, at(10, 0), at(10, 20))]);
  });

  test('an in-app switch reported pause-first stays one session, and a stop '
      'for an already paused activity changes nothing (fixture two_activities_pause_first)', () {
    final r = run(fixture('two_activities_pause_first'));
    expect(r.sessions, [s(notes, at(10, 0), at(10, 20))]);
  });

  test('the same app resuming long after its pause starts a new session', () {
    final r = run([
      ev(at(9, 0), video, 'Main', EventKind.resumed),
      ev(at(9, 30), video, 'Main', EventKind.paused),
      ev(at(9, 45), video, 'Main', EventKind.resumed),
      ev(at(10, 0), video, 'Main', EventKind.paused),
    ]);
    expect(r.sessions, [s(video, at(9, 0), at(9, 30)), s(video, at(9, 45), at(10, 0))]);
  });

  group('a resume with no pause', () {
    test('is closed by another app resuming', () {
      final r = run([
        ev(at(9, 0), video, 'Main', EventKind.resumed),
        ev(at(9, 20), chat, 'Main', EventKind.resumed),
        ev(at(9, 25), chat, 'Main', EventKind.paused),
      ]);
      expect(r.sessions, [s(video, at(9, 0), at(9, 20)), s(chat, at(9, 20), at(9, 25))]);
    });

    test('is closed by screenOff', () {
      final r = run([
        ev(at(9, 0), video, 'Main', EventKind.resumed),
        ev(at(9, 40), 'android', null, EventKind.screenOff),
        ev(at(10, 0), 'android', null, EventKind.screenOn),
      ]);
      expect(r.sessions, [s(video, at(9, 0), at(9, 40))]);
      expect(r.idle, [IdleSpan(at(9, 40), at(10, 0), IdleKind.screenOff)]);
    });

    test('is closed by shutdown, and shutdown to startup is idle', () {
      final r = run([
        ev(at(18, 0), video, 'Main', EventKind.resumed),
        ev(at(18, 30), 'android', null, EventKind.shutdown),
        ev(at(18, 40), 'android', null, EventKind.startup),
      ]);
      expect(r.sessions, [s(video, at(18, 0), at(18, 30))]);
      expect(r.idle, [IdleSpan(at(18, 30), at(18, 40), IdleKind.shutdown)]);
    });

    test('is closed at now when it is the app in front', () {
      final r = run([ev(at(15, 0), video, 'Main', EventKind.resumed)], now: at(15, 20));
      expect(r.sessions, [s(video, at(15, 0), at(15, 20))]);
    });
  });

  test('the launcher, System UI and Drift give idle, not sessions (fixture idle_apps)', () {
    final r = run(fixture('idle_apps'));
    expect(r.sessions, [s(video, at(8, 1, 0, 300), at(8, 10))]);
    expect(r.idle, [
      IdleSpan(at(8, 0), at(8, 1), IdleKind.idleApp),
      IdleSpan(at(8, 10, 0, 300), at(8, 11), IdleKind.idleApp),
      IdleSpan(at(8, 11, 0, 300), at(8, 15), IdleKind.idleApp),
    ]);
  });

  test('keyguard shown and hidden give a locked span (fixture keyguard)', () {
    final r = run(fixture('keyguard'));
    expect(r.sessions, [s(video, at(21, 0), at(21, 30)), s(video, at(22, 0, 6), at(22, 10))]);
    expect(r.idle, [
      IdleSpan(at(21, 30), at(22, 0), IdleKind.screenOff),
      IdleSpan(at(21, 30, 1), at(22, 0, 5), IdleKind.locked),
    ]);
  });

  test('a startup with no shutdown closes everything at the last event '
      '(fixture startup_no_shutdown)', () {
    final r = run(fixture('startup_no_shutdown'));
    expect(r.sessions, [s(chat, at(13, 0), at(13, 20)), s(chat, at(13, 46), at(14, 0))]);
    expect(r.idle, [IdleSpan(at(13, 20), at(13, 45), IdleKind.shutdown)]);
  });

  test('duplicate events from a buffer file and the direct query count once '
      '(fixture duplicates)', () {
    final r = run(fixture('duplicates'), now: DateTime(2026, 10, 20, 1));
    expect(r.sessions, [s(video, at(23, 31), at(23, 40))]);
    expect(r.idle, [IdleSpan(at(23, 0), at(23, 30), IdleKind.screenOff)]);
  });

  test('an empty event list gives nothing', () {
    final r = run(const []);
    expect(r.sessions, isEmpty);
    expect(r.idle, isEmpty);
  });

  test('a screen still off at now is idle up to now', () {
    final r = run([ev(at(1, 0), 'android', null, EventKind.screenOff)], now: at(7, 0));
    expect(r.idle, [IdleSpan(at(1, 0), at(7, 0), IdleKind.screenOff)]);
  });

  test('unknown kinds are dropped when parsing', () {
    expect(RawEvent.fromMap({'t': 1, 'p': video, 'c': null, 'k': 'configChange'}), isNull);
    expect(RawEvent.fromMap({'t': 1, 'p': video, 'c': null, 'k': 'resumed'}),
        RawEvent(1, video, null, EventKind.resumed));
    expect(RawEvent.fromMap({'p': video, 'k': 'resumed'}), isNull);
  });
}
