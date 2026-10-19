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

  ThemeId _theme = ThemeId.mono;
  TodayView _todayView = TodayView.lanes;
  bool _updateOnLaunch = true;
  DateTime? _updateLastCheck;
  String? _updateDismissedTag;
  String? _updateInstallingTag;

  ThemeId get theme => _theme;
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
    notifyListeners();
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
