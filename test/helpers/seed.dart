import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/models.dart';

/// Made-up apps, one per category Drift treats differently.
const sampleApps = [
  AppInfo(p: 'com.example.video', label: 'YouTube', category: 'video'),
  AppInfo(p: 'com.example.social', label: 'Instagram', category: 'social'),
  AppInfo(p: 'com.example.chat', label: 'WhatsApp', category: 'social'),
  AppInfo(p: 'com.example.notes', label: 'Notes', category: 'productivity'),
  AppInfo(p: 'com.example.music', label: 'Spotify', category: 'audio'),
  AppInfo(p: 'com.example.meet', label: 'Zoom', category: 'productivity'),
];

/// The weekday plan from the mockups, every weekday.
const samplePlan = [
  PlanBlock(name: 'Gym', startMin: 8 * 60, endMin: 9 * 60, repeatMask: PlanBlock.weekdays),
  PlanBlock(name: 'Deep work', startMin: 9 * 60, endMin: 12 * 60, repeatMask: PlanBlock.weekdays),
  PlanBlock(name: 'Lunch', startMin: 12 * 60, endMin: 13 * 60, repeatMask: PlanBlock.weekdays, anyApp: true),
  PlanBlock(name: 'Meetings', startMin: 13 * 60, endMin: 14 * 60, repeatMask: PlanBlock.weekdays),
  PlanBlock(name: 'Family', startMin: 18 * 60, endMin: 21 * 60, repeatMask: PlanBlock.weekdays),
];

/// Fills [day] with the sample plan, rules and a morning of app use that
/// has on-track, off-track, guessed and idle time in it.
Future<void> seedSampleDay(AppServices s, DateTime day) async {
  final d = DateTime(day.year, day.month, day.day);
  DateTime at(int h, int m) => DateTime(d.year, d.month, d.day, h, m);

  await s.apps.upsertAll(sampleApps, d);
  for (final b in samplePlan) {
    await s.plans.insertBlock(b);
  }
  await s.rules.upsertRule('Deep work', 'com.example.notes', Verdict.onTrack, d);
  await s.rules.upsertRule('Deep work', 'com.example.video', Verdict.offTrack, d);
  await s.rules.upsertRule('Deep work', 'com.example.social', Verdict.offTrack, d);
  await s.rules.upsertRule('Meetings', 'com.example.meet', Verdict.onTrack, d);

  await s.sessions.replaceDay(
    d,
    DateTime(d.year, d.month, d.day + 1),
    [
      Session(p: 'com.example.music', start: at(8, 10), end: at(8, 50)),
      Session(p: 'com.example.notes', start: at(9, 5), end: at(9, 35)),
      Session(p: 'com.example.social', start: at(9, 40), end: at(10, 5)),
      Session(p: 'com.example.chat', start: at(10, 15), end: at(10, 24)),
      Session(p: 'com.example.notes', start: at(10, 30), end: at(11, 10)),
      Session(p: 'com.example.video', start: at(11, 15), end: at(11, 50)),
      Session(p: 'com.example.video', start: at(12, 10), end: at(12, 40)),
      Session(p: 'com.example.meet', start: at(13, 5), end: at(13, 25)),
    ],
    [
      IdleSpan(at(7, 0), at(8, 10), IdleKind.screenOff),
      IdleSpan(at(11, 50), at(12, 10), IdleKind.locked),
    ],
  );
}
