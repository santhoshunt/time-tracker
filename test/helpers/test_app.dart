import 'package:drift_time/app_services.dart';
import 'package:drift_time/data/drift_db.dart';
import 'package:drift_time/domain/clock.dart';
import 'package:drift_time/platform/icon_switcher.dart';
import 'package:drift_time/platform/nudge_bridge.dart';
import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_usage_source.dart';

/// Monday 19 October 2026, 13:30 local: mid-afternoon on a weekday, so a
/// day has both past and future blocks.
final testNow = DateTime(2026, 10, 19, 13, 30);

/// Records icon switches instead of talking to Android.
class FakeIconSwitcher implements IconSwitcher {
  String currentAlias = iconAliasNames.first;
  final sets = <String>[];

  @override
  Future<String> current() async => currentAlias;

  @override
  Future<void> set(String aliasName) async {
    sets.add(aliasName);
    currentAlias = aliasName;
  }
}

/// Records service starts and stops; permissions are plain fields.
class FakeNudgeBridge implements NudgeBridge {
  bool overlay = false;
  bool notifications = false;
  bool running = false;
  int starts = 0;
  int stops = 0;
  int notificationRequests = 0;

  @override
  Future<bool> canDrawOverlays() async => overlay;

  @override
  Future<void> openOverlaySettings() async {}

  @override
  Future<bool> hasNotificationPermission() async => notifications;

  @override
  Future<bool> requestNotificationPermission() async {
    notificationRequests++;
    return notifications;
  }

  @override
  Future<void> startService() async {
    starts++;
    running = true;
  }

  @override
  Future<void> stopService() async {
    stops++;
    running = false;
  }

  @override
  Future<Map<String, Object?>> serviceStatus() async => {'running': running};
}

/// AppServices over an in-memory database and fakes. Each call gets a
/// fresh database.
Future<AppServices> testServices({
  FakeUsageSource? usage,
  FakeIconSwitcher? icons,
  FakeNudgeBridge? nudges,
  DateTime? now,
}) async {
  sqfliteFfiInit();
  final db = await openDriftDb(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
  return AppServices(
    db: db,
    usage: usage ?? FakeUsageSource(),
    icons: icons ?? FakeIconSwitcher(),
    clock: FixedClock(now ?? testNow),
    nudges: nudges ?? FakeNudgeBridge(),
  );
}

/// Settings backed by mock SharedPreferences.
Future<SettingsProvider> testSettings({ThemeId theme = ThemeId.mono}) async {
  SharedPreferences.setMockInitialValues({'theme_v1': theme.key});
  final settings = SettingsProvider();
  await settings.load();
  return settings;
}

/// Wraps [child] in the providers and theme the app gives every screen.
Widget withApp(
  AppServices services,
  SettingsProvider settings,
  Widget child,
) => MultiProvider(
  providers: [
    Provider<AppServices>.value(value: services),
    ChangeNotifierProvider<SettingsProvider>.value(value: settings),
  ],
  child: Consumer<SettingsProvider>(
    builder: (context, s, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildDriftTheme(s.theme),
      home: child,
    ),
  ),
);

/// Just the providers, for [pumpGolden], which brings its own MaterialApp.
Widget withProviders(
  AppServices services,
  SettingsProvider settings,
  Widget child,
) => MultiProvider(
  providers: [
    Provider<AppServices>.value(value: services),
    ChangeNotifierProvider<SettingsProvider>.value(value: settings),
  ],
  child: child,
);
