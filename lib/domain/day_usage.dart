import '../platform/usage_source.dart';
import 'models.dart';
import 'sessionizer.dart';

/// Drift's own package; its time is never counted. Repeated here rather
/// than imported from app_services.dart so lib/domain stays free of the
/// app's service wiring.
const _driftPackage = 'io.github.santhoshunt.drift';

/// Whether time on [p] counts as distracting in the Today notification,
/// plan or no plan: an off-track rule for any block makes it distracting;
/// otherwise a category guessed off track does, unless an on-track rule
/// says the app belongs somewhere in the plan.
///
/// DayUsage.kt applies the same rule on the phone; test/fixtures/
/// usage_count_cases.json keeps the two in step.
bool isDistracting(
  String p,
  String category, {
  required Set<String> offApps,
  required Set<String> onApps,
  required Set<String> guessOff,
}) =>
    offApps.contains(p) || (!onApps.contains(p) && guessOff.contains(category));

/// Today's app time and the distracting share of it, as the Today
/// notification shows them.
///
/// [events] may start before [dayStartMs] (the phone reads three hours
/// more, so an app already open at midnight is seen); sessions are built
/// with [buildSessions] and clipped to [dayStartMs, nowMs]. Drift is left
/// out, and when [launchable] is not empty so is every package missing from
/// it, as the Usage tab does. A package missing from [categories] counts as
/// [AppCategories.undefined].
({int totalMs, int distractingMs}) countDayUsage(
  List<RawEvent> events, {
  required int dayStartMs,
  required int nowMs,
  required Set<String> idlePackages,
  required Set<String> launchable,
  required Map<String, String> categories,
  required Set<String> offApps,
  required Set<String> onApps,
  required Set<String> guessOff,
}) {
  final sessions = buildSessions(
    events,
    idlePackages: idlePackages,
    now: DateTime.fromMillisecondsSinceEpoch(nowMs),
  ).sessions;
  var total = 0;
  var distracting = 0;
  for (final s in sessions) {
    if (s.p == _driftPackage) continue;
    if (launchable.isNotEmpty && !launchable.contains(s.p)) continue;
    final a = s.start.millisecondsSinceEpoch;
    final b = s.end.millisecondsSinceEpoch;
    final from = a < dayStartMs ? dayStartMs : a;
    final to = b > nowMs ? nowMs : b;
    if (to <= from) continue;
    total += to - from;
    final category = categories[s.p] ?? AppCategories.undefined;
    if (isDistracting(s.p, category, offApps: offApps, onApps: onApps, guessOff: guessOff)) {
      distracting += to - from;
    }
  }
  return (totalMs: total, distractingMs: distracting);
}
