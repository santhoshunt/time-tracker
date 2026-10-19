/// The four themes Sandy picked. Mono is the default. The `key` is what
/// SharedPreferences stores, so it must never change.
enum ThemeId {
  mono('mono', 'Mono'),
  blackCyan('blackCyan', 'Black and cyan'),
  cleanLight('cleanLight', 'Clean light'),
  warmPaper('warmPaper', 'Warm paper');

  const ThemeId(this.key, this.label);

  final String key;
  final String label;

  static ThemeId fromKey(String? key) => ThemeId.values.firstWhere(
    (t) => t.key == key,
    orElse: () => ThemeId.mono,
  );
}

/// How the Today tab draws the day: two lanes or a 24-hour ring.
enum TodayView {
  lanes('lanes'),
  ring('ring');

  const TodayView(this.key);

  final String key;

  static TodayView fromKey(String? key) => TodayView.values.firstWhere(
    (v) => v.key == key,
    orElse: () => TodayView.lanes,
  );
}
