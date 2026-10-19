import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'app_services.dart';
import 'providers/settings_provider.dart';
import 'services/update_downloader.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsProvider();
  await settings.load();
  final services = await AppServices.open();
  // A download left behind by an install that never finished.
  unawaited(UpdateDownloader().cleanup());
  runApp(DriftApp(services: services, settings: settings));
}
