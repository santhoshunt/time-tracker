import 'package:drift_time/app_services.dart';
import 'package:drift_time/data/drift_db.dart';
import 'package:drift_time/domain/clock.dart';
import 'package:drift_time/platform/icon_switcher.dart';
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

/// AppServices over an in-memory database and fakes. Each call gets a
/// fresh database.
Future<AppServices> testServices({
  FakeUsageSource? usage,
  FakeIconSwitcher? icons,
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
