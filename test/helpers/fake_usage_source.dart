import 'dart:convert';
import 'dart:io';

import 'package:drift_time/platform/usage_source.dart';

/// Loads `test/fixtures/events/<name>.json` as event maps in the
/// queryEvents shape. Fixture times are local ISO strings, which read
/// better than epoch milliseconds; they become UTC ms here.
List<Map<String, Object?>> loadEventFixture(String name) {
  final json = jsonDecode(File('test/fixtures/events/$name.json').readAsStringSync())
      as Map<String, dynamic>;
  return [
    for (final e in json['events'] as List<dynamic>)
      {
        't': DateTime.parse(e['t'] as String).millisecondsSinceEpoch,
        'p': e['p'],
        'c': e['c'],
        'k': e['k'],
      },
  ];
}

/// One event map in the queryEvents shape, at local time [t].
Map<String, Object?> eventMap(DateTime t, String p, String? c, String k) =>
    {'t': t.millisecondsSinceEpoch, 'p': p, 'c': c, 'k': k};

/// An in-memory [UsageSource] for domain and screen tests.
///
/// Events, apps, launchers and buffer files are plain fields a test fills
/// in. Buffer files are a path-to-text map; pass [readFile] to the
/// Ingestor as its buffer reader so nothing touches the disk. Calls that
/// change state are recorded so tests can assert on them.
class FakeUsageSource implements UsageSource {
  FakeUsageSource({
    List<Map<String, Object?>>? events,
    List<Map<String, Object?>>? apps,
    Map<String, String>? bufferFiles,
    List<String>? homePackages,
    this.usageAccess = true,
    this.ignoringBatteryOptimizations = true,
    this.earliestOverride,
    this.useEarliestOverride = false,
  })  : events = events ?? [],
        apps = apps ?? [],
        bufferFiles = bufferFiles ?? {},
        home = homePackages ?? ['com.example.launcher'];

  /// Every event Android "holds", in the queryEvents map shape.
  final List<Map<String, Object?>> events;

  /// What listApps returns.
  final List<Map<String, Object?>> apps;

  /// Buffer files still on "disk": absolute path to file text.
  final Map<String, String> bufferFiles;

  /// What homePackages returns.
  final List<String> home;

  bool usageAccess;
  bool ignoringBatteryOptimizations;

  /// When [useEarliestOverride] is set, earliestEventMs returns this
  /// instead of the oldest event's time.
  int? earliestOverride;
  bool useEarliestOverride;

  /// Called inside deleteBuffer before the files go, so a test can check
  /// what was already committed at that moment.
  Future<void> Function(List<String> paths)? onDeleteBuffer;

  final deletedBuffers = <String>[];
  final queries = <(int, int)>[];
  int listAppsCalls = 0;
  int openUsageSettingsCalls = 0;
  int requestBatteryCalls = 0;

  /// Reads a buffer file from [bufferFiles]; a missing path throws like a
  /// missing file would.
  Future<String> readFile(String path) async {
    final text = bufferFiles[path];
    if (text == null) throw StateError('No buffer file $path');
    return text;
  }

  @override
  Future<bool> hasUsageAccess() async => usageAccess;

  @override
  Future<void> openUsageAccessSettings() async => openUsageSettingsCalls++;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => ignoringBatteryOptimizations;

  @override
  Future<void> requestIgnoreBatteryOptimizations() async => requestBatteryCalls++;

  @override
  Future<List<Map<String, Object?>>> queryEvents({required int fromMs, required int toMs}) async {
    queries.add((fromMs, toMs));
    // Sorted by time with ties kept in insertion order, as Android does.
    final indexed = [
      for (var i = 0; i < events.length; i++)
        if ((events[i]['t'] as int) >= fromMs && (events[i]['t'] as int) < toMs) (i, events[i]),
    ];
    indexed.sort((a, b) {
      final byTime = (a.$2['t'] as int).compareTo(b.$2['t'] as int);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
    return [for (final (_, e) in indexed) Map<String, Object?>.of(e)];
  }

  @override
  Future<int?> earliestEventMs() async {
    if (useEarliestOverride) return earliestOverride;
    if (events.isEmpty) return null;
    return events.map((e) => e['t'] as int).reduce((a, b) => a < b ? a : b);
  }

  @override
  Future<List<Map<String, Object?>>> listApps() async {
    listAppsCalls++;
    return [for (final a in apps) Map<String, Object?>.of(a)];
  }

  @override
  Future<List<int>?> appIcon(String package) async => null;

  @override
  Future<List<String>> homePackages() async => List.of(home);

  @override
  Future<List<String>> drainBuffer() async => bufferFiles.keys.toList()..sort();

  @override
  Future<void> deleteBuffer(List<String> paths) async {
    await onDeleteBuffer?.call(paths);
    for (final p in paths) {
      bufferFiles.remove(p);
      deletedBuffers.add(p);
    }
  }

  @override
  Future<Map<String, Object?>> diagnostics() async => {
        'workerLastRunMs': null,
        'bufferFiles': bufferFiles.length,
        'bufferCursorMs': null,
      };

  /// Saved exports by file name; set [saveFails] to make the next save throw.
  final savedCsv = <String, String>{};
  bool saveFails = false;

  @override
  Future<String> saveCsv(String name, String text) async {
    if (saveFails) throw Exception('Disk full');
    savedCsv[name] = text;
    return 'Downloads/Drift/$name';
  }
}
