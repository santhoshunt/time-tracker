import 'dart:async';

import 'package:flutter/material.dart';

import 'boot.dart';
import 'services/update_downloader.dart';

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      // Draw at once: startup work happens inside BootApp, which shows any
      // failure on screen instead of leaving the launch screen up.
      runApp(const BootApp());
      // A download left behind by an install that never finished.
      unawaited(UpdateDownloader().cleanup());
    },
    (error, stack) => debugPrint('Uncaught: $error\n$stack'),
  );
}
