import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drift_time/providers/settings_provider.dart';
import 'package:drift_time/services/update_downloader.dart';
import 'package:drift_time/services/update_installer.dart';
import 'package:drift_time/services/update_service.dart';
import 'package:drift_time/widgets/update_banner.dart';
import 'package:drift_time/widgets/update_sheet.dart';

ReleaseOption opt(String tag) => ReleaseOption(
  tag: tag,
  publishedAt: DateTime(2026, 9, 26),
  sizeBytes: 68 * 1024 * 1024,
  notes: 'What changed in $tag',
  downloadUrl: UpdateService.assetUrlFor(tag),
);

class FakeInstaller implements UpdateInstaller {
  bool allowed = true;
  String? refusal;
  int installs = 0;
  int settingsOpened = 0;

  @override
  Future<bool> canInstall() async => allowed;

  @override
  Future<void> openInstallSettings() async => settingsOpened++;

  @override
  Future<String?> install(File apk) async {
    installs++;
    return refusal;
  }
}

class FakeDownloader extends UpdateDownloader {
  int downloads = 0;
  int cleanups = 0;

  @override
  Future<File> download(
    ReleaseOption option, {
    void Function(int received, int total)? onProgress,
    DownloadCancel? cancel,
  }) async {
    downloads++;
    return File('${option.tag}.apk');
  }

  @override
  Future<void> cleanup() async => cleanups++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    availableUpdate.value = null;
  });

  Future<SettingsProvider> pumpWith(WidgetTester tester, Widget body) async {
    final settings = SettingsProvider();
    await settings.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(home: Scaffold(body: body)),
      ),
    );
    return settings;
  }

  test("the sheet names Drift's own package", () {
    expect(kAppPackage, 'io.github.santhoshunt.drift');
  });

  testWidgets('the banner offers the newest version; Not now waits for a '
      'newer one', (tester) async {
    await pumpWith(tester, const UpdateBanner());
    expect(find.textContaining('is ready'), findsNothing);

    availableUpdate.value = UpdateList('1.20.0', [
      opt('v1.20.2'),
      opt('v1.20.1'),
    ]);
    await tester.pump();
    expect(find.text('Drift v1.20.2 is ready'), findsOneWidget);
    expect(find.text('2 newer versions on GitHub.'), findsOneWidget);
    expect(find.text('See versions'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pump();
    expect(find.textContaining('is ready'), findsNothing);

    availableUpdate.value = UpdateList('1.20.0', [opt('v1.20.3')]);
    await tester.pump();
    expect(find.text('Drift v1.20.3 is ready'), findsOneWidget);
    expect(find.text('A newer version is on GitHub.'), findsOneWidget);
  });

  Future<(FakeInstaller, FakeDownloader)> openSheet(
    WidgetTester tester, {
    bool allowed = true,
    String? refusal,
  }) async {
    final installer = FakeInstaller()
      ..allowed = allowed
      ..refusal = refusal;
    final downloader = FakeDownloader();
    await pumpWith(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showUpdateSheet(
            context,
            UpdateList('1.20.0', [opt('v1.21.0'), opt('v1.20.1')]),
            installer: installer,
            downloader: downloader,
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (installer, downloader);
  }

  testWidgets('the sheet names the download URL and the checks before any '
      'tap', (tester) async {
    final (installer, downloader) = await openSheet(tester);
    expect(find.text('Choose a version'), findsOneWidget);
    expect(find.text('v1.21.0'), findsOneWidget);
    expect(find.text('v1.20.1'), findsOneWidget);
    expect(find.text(UpdateService.assetUrlFor('v1.21.0')), findsOneWidget);
    expect(find.textContaining(kAppPackage), findsOneWidget);
    expect(find.text("It is signed with this app's key"), findsOneWidget);
    expect(downloader.downloads, 0, reason: 'nothing before the tap');

    await tester.tap(find.text('v1.20.1'));
    await tester.pump();
    expect(find.text(UpdateService.assetUrlFor('v1.20.1')), findsOneWidget);
    expect(installer.installs, 0);
  });

  testWidgets('without the install permission it explains and opens '
      'settings', (tester) async {
    final (installer, downloader) = await openSheet(tester, allowed: false);
    // The newest notes start open and push the button down.
    await tester.ensureVisible(find.text('Download & install'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download & install'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Android needs your OK first'), findsOneWidget);
    expect(find.textContaining('for Drift'), findsOneWidget);
    expect(downloader.downloads, 0);
    // The sheet scrolls; the Release page link pushed the button down.
    await tester.ensureVisible(find.text('Open settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open settings'));
    await tester.pump();
    expect(installer.settingsOpened, 1);
  });

  testWidgets('a double tap starts one download', (tester) async {
    final (installer, downloader) = await openSheet(tester, refusal: 'refused');
    await tester.ensureVisible(find.text('Download & install'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download & install'));
    await tester.tap(find.text('Download & install'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(downloader.downloads, 1);
    expect(installer.installs, 1);
  });
  testWidgets('a refused install closes the sheet and says why, with the '
      'release page', (tester) async {
    final (installer, downloader) = await openSheet(
      tester,
      refusal: "This update is not signed with this app's key.",
    );
    await tester.ensureVisible(find.text('Download & install'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download & install'));
    await tester.pumpAndSettle();
    expect(downloader.downloads, 1);
    expect(installer.installs, 1);
    expect(downloader.cleanups, greaterThan(0), reason: 'no APK left');
    expect(find.text('Choose a version'), findsNothing);
    expect(
      find.text("This update is not signed with this app's key."),
      findsOneWidget,
    );
    expect(find.text('Release page'), findsOneWidget);
  });
}
