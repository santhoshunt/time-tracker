import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/theme_id.dart';

/// App preferences kept in SharedPreferences. Keys end in a version suffix
/// and are never renamed or removed, so an update never loses a setting.
///
/// The four update keys and their methods mirror the expense tracker's
/// SettingsProvider, which the copied updater code calls.
class SettingsProvider extends ChangeNotifier {
  static const _kTheme = 'theme_v1';
  static const _kTodayView = 'today_view_v1';
  static const _kUpdateOnLaunch = 'update_check_on_launch_v1';
  static const _kUpdateLastCheck = 'update_last_check_v1';
  static const _kUpdateDismissed = 'update_dismissed_tag_v1';
  static const _kUpdateInstalling = 'update_installing_tag_v1';
  static const _kNudgesEnabled = 'nudges_enabled_v1';
  static const _kNudgeAfter = 'nudge_after_min_v1';
  static const _kNudgeRepeat = 'nudge_repeat_min_v1';
  static const _kQuietStart = 'quiet_start_min_v1';
  static const _kQuietEnd = 'quiet_end_min_v1';
  static const _kSkippedSetup = 'setup_skipped_v1';
  static const _kWeekStart = 'week_start_v1';
  static const _kLastUpdateVersion = 'update_last_success_version_v1';
  static const _kLastUpdateMs = 'update_last_success_ms_v1';

  ThemeId _theme = ThemeId.mono;
  TodayView _todayView = TodayView.lanes;
  bool _updateOnLaunch = true;
  DateTime? _updateLastCheck;
  String? _updateDismissedTag;
  String? _updateInstallingTag;
  String? _lastUpdateVersion;
  DateTime? _lastUpdateAt;
  bool _nudgesEnabled = true;
  int _nudgeAfterMin = 5;
  int _nudgeRepeatMin = 15;
  int _quietStartMin = 22 * 60;
  int _quietEndMin = 7 * 60;
  Set<String> _skippedSetup = const {};
  int _firstWeekday = DateTime.monday;

  ThemeId get theme => _theme;

  /// DateTime.monday or DateTime.sunday: where week reviews start.
  int get firstWeekday => _firstWeekday;

  /// Live nudges on or off. On by default, as Sandy asked for both live
  /// nudges and the end-of-day review.
  bool get nudgesEnabled => _nudgesEnabled;

  /// Minutes of continuous off-track use before a nudge.
  int get nudgeAfterMin => _nudgeAfterMin;

  /// Minimum minutes between two nudges.
  int get nudgeRepeatMin => _nudgeRepeatMin;

  /// Quiet hours, as minutes from local midnight; equal means none.
  int get quietStartMin => _quietStartMin;
  int get quietEndMin => _quietEndMin;

  /// Optional setup pages the user answered with "Not now".
  Set<String> get skippedSetup => _skippedSetup;

  /// The version the last in-app update installed, and when the app first
  /// started on it. Diagnostics shows it, so a pasted report proves the
  /// updater worked on the phone.
  String? get lastUpdateVersion => _lastUpdateVersion;
  DateTime? get lastUpdateAt => _lastUpdateAt;
  TodayView get todayView => _todayView;

  /// Whether to look for a newer GitHub release once a day on launch.
  bool get updateOnLaunch => _updateOnLaunch;

  /// When the last launch check succeeded (up to date or update found).
  DateTime? get updateLastCheck => _updateLastCheck;

  /// The newest tag the user dismissed with "Not now"; hides the banner
  /// until a newer release appears.
  String? get updateDismissedTag => _updateDismissedTag;

  /// Set just before handing an APK to the installer, so the next launch
  /// can say "Updated to vX". Cleared on that launch.
  String? get updateInstallingTag => _updateInstallingTag;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _theme = ThemeId.fromKey(_read(() => prefs.getString(_kTheme), null));
    _todayView = TodayView.fromKey(
      _read(() => prefs.getString(_kTodayView), null),
    );
    _updateOnLaunch = _read(() => prefs.getBool(_kUpdateOnLaunch) ?? true, true);
    _updateLastCheck = _read(() {
      final ms = prefs.getInt(_kUpdateLastCheck);
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    }, null);
    _updateDismissedTag = _read(() => prefs.getString(_kUpdateDismissed), null);
    _updateInstallingTag = _read(
      () => prefs.getString(_kUpdateInstalling),
      null,
    );
    _lastUpdateVersion = _read(() => prefs.getString(_kLastUpdateVersion), null);
    _lastUpdateAt = _read(() {
      final ms = prefs.getInt(_kLastUpdateMs);
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    }, null);
    _nudgesEnabled = _read(() => prefs.getBool(_kNudgesEnabled) ?? true, true);
    _nudgeAfterMin = _read(() => prefs.getInt(_kNudgeAfter) ?? 5, 5);
    _nudgeRepeatMin = _read(() => prefs.getInt(_kNudgeRepeat) ?? 15, 15);
    _quietStartMin = _read(() => prefs.getInt(_kQuietStart) ?? 22 * 60, 22 * 60);
    _quietEndMin = _read(() => prefs.getInt(_kQuietEnd) ?? 7 * 60, 7 * 60);
    _skippedSetup = _read(
      () => (prefs.getStringList(_kSkippedSetup) ?? const []).toSet(),
      const <String>{},
    );
    _firstWeekday = _read(
      () => prefs.getString(_kWeekStart) == 'sunday'
          ? DateTime.sunday
          : DateTime.monday,
      DateTime.monday,
    );
    notifyListeners();
  }

  Future<void> setFirstWeekday(int day) async {
    final value = day == DateTime.sunday ? DateTime.sunday : DateTime.monday;
    if (value == _firstWeekday) return;
    _firstWeekday = value;
    notifyListeners();
    await _persist(
      _kWeekStart,
      (p) => p.setString(
        _kWeekStart,
        value == DateTime.sunday ? 'sunday' : 'monday',
      ),
    );
  }

  Future<void> setNudgesEnabled(bool value) async {
    if (value == _nudgesEnabled) return;
    _nudgesEnabled = value;
    notifyListeners();
    await _persist(_kNudgesEnabled, (p) => p.setBool(_kNudgesEnabled, value));
  }

  Future<void> setNudgeAfterMin(int value) async {
    if (value == _nudgeAfterMin) return;
    _nudgeAfterMin = value;
    notifyListeners();
    await _persist(_kNudgeAfter, (p) => p.setInt(_kNudgeAfter, value));
  }

  Future<void> setNudgeRepeatMin(int value) async {
    if (value == _nudgeRepeatMin) return;
    _nudgeRepeatMin = value;
    notifyListeners();
    await _persist(_kNudgeRepeat, (p) => p.setInt(_kNudgeRepeat, value));
  }

  Future<void> setQuietHours(int startMin, int endMin) async {
    _quietStartMin = startMin;
    _quietEndMin = endMin;
    notifyListeners();
    await _persist(_kQuietStart, (p) async {
      await p.setInt(_kQuietStart, startMin);
      await p.setInt(_kQuietEnd, endMin);
    });
  }

  Future<void> skipSetup(String key) async {
    if (_skippedSetup.contains(key)) return;
    _skippedSetup = {..._skippedSetup, key};
    notifyListeners();
    await _persist(
      _kSkippedSetup,
      (p) => p.setStringList(_kSkippedSetup, _skippedSetup.toList()),
    );
  }

  Future<void> recordUpdateSuccess(String version, DateTime when) async {
    _lastUpdateVersion = version;
    _lastUpdateAt = when;
    notifyListeners();
    await _persist(_kLastUpdateVersion, (p) async {
      await p.setString(_kLastUpdateVersion, version);
      await p.setInt(_kLastUpdateMs, when.millisecondsSinceEpoch);
    });
  }

  Future<void> setTheme(ThemeId value) async {
    if (value == _theme) return;
    _theme = value;
    notifyListeners();
    await _persist(_kTheme, (p) => p.setString(_kTheme, value.key));
  }

  Future<void> setTodayView(TodayView value) async {
    if (value == _todayView) return;
    _todayView = value;
    notifyListeners();
    await _persist(_kTodayView, (p) => p.setString(_kTodayView, value.key));
  }

  Future<void> setUpdateOnLaunch(bool value) async {
    if (value == _updateOnLaunch) return;
    _updateOnLaunch = value;
    notifyListeners();
    await _persist(_kUpdateOnLaunch, (p) => p.setBool(_kUpdateOnLaunch, value));
  }

  Future<void> markUpdateChecked(DateTime when) async {
    _updateLastCheck = when;
    await _persist(
      _kUpdateLastCheck,
      (p) => p.setInt(_kUpdateLastCheck, when.millisecondsSinceEpoch),
    );
  }

  Future<void> dismissUpdate(String tag) async {
    if (tag == _updateDismissedTag) return;
    _updateDismissedTag = tag;
    notifyListeners();
    await _persist(_kUpdateDismissed, (p) => p.setString(_kUpdateDismissed, tag));
  }

  Future<void> setUpdateInstallingTag(String? tag) async {
    _updateInstallingTag = tag;
    await _persist(
      _kUpdateInstalling,
      (p) => tag == null
          ? p.remove(_kUpdateInstalling)
          : p.setString(_kUpdateInstalling, tag),
    );
  }

  /// A corrupt or wrongly typed value falls back to the default instead of
  /// stopping the app from starting.
  T _read<T>(T Function() read, T fallback) {
    try {
      return read();
    } catch (e) {
      debugPrint('Settings read failed: $e');
      return fallback;
    }
  }

  /// The in-memory value stands even if the write fails; it just won't
  /// survive a restart. Logged only, since re-setting the preference
  /// recovers it.
  Future<void> _persist(
    String what,
    Future<void> Function(SharedPreferences p) write,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await write(prefs);
    } catch (e) {
      debugPrint('Settings persist failed ($what): $e');
    }
  }
}
