import 'models.dart';

/// Keeps only sessions of apps the user can open from the home screen.
/// Every other session (Google Play services handling a sign-in, the
/// permission dialog, the share sheet) is a system component another app
/// called up for a moment, not something the user chose, so its time is
/// added to [idleOut] as idle instead.
///
/// [launchable] is the apps table. When it is empty (before the first
/// app-list refresh) nothing is reclassified, so a new install never hides
/// real use.
List<Session> withoutSystemApps(
  List<Session> sessions,
  Set<String> launchable,
  List<IdleSpan> idleOut,
) {
  if (launchable.isEmpty) return sessions;
  final kept = <Session>[];
  for (final s in sessions) {
    if (launchable.contains(s.p)) {
      kept.add(s);
    } else {
      idleOut.add(IdleSpan(s.start, s.end, IdleKind.idleApp));
    }
  }
  return kept;
}
