import 'dart:convert';

import 'package:drift_time/theme/drift_theme.dart';
import 'package:drift_time/theme/theme_id.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _fontsLoaded = false;

/// Loads every font family the app bundles (Roboto and MaterialIcons)
/// from FontManifest.json, so goldens show real glyphs instead of the test
/// font's boxes. Call it from `setUpAll`; repeat calls do nothing.
Future<void> loadDriftFonts() async {
  if (_fontsLoaded) return;
  final manifest =
      json.decode(await rootBundle.loadString('FontManifest.json'))
          as List<dynamic>;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(entry['family'] as String);
    for (final font in (entry['fonts'] as List<dynamic>)
        .cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  _fontsLoaded = true;
}

/// Pumps [child] as a phone screen of [size] logical pixels at a device
/// pixel ratio of 2, inside a MaterialApp themed with [theme] and scaled
/// text. The view is reset when the test ends. A RenderFlex overflow still
/// fails the test, as it does by default.
///
/// It ends with `pumpAndSettle`, so a screen that never settles, such as
/// one with an indeterminate progress indicator, times out here.
Future<void> pumpGolden(
  WidgetTester tester,
  Widget child, {
  ThemeId theme = ThemeId.mono,
  Size size = const Size(393, 851),
  double textScale = 1.0,
}) async {
  const dpr = 2.0;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = size * dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildDriftTheme(theme),
      // MaterialApp builds its own MediaQuery from the view, so the text
      // scale has to be applied inside it.
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: app!,
      ),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}
