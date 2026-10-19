import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'data/drift_db.dart';
import 'data/repositories/app_repository.dart';
import 'data/repositories/event_repository.dart';
import 'data/repositories/meta_repository.dart';
import 'data/repositories/plan_repository.dart';
import 'data/repositories/rule_repository.dart';
import 'data/repositories/session_repository.dart';
import 'domain/clock.dart';
import 'domain/ingestor.dart';
import 'platform/channel_usage_source.dart';
import 'platform/icon_switcher.dart';
import 'platform/usage_source.dart';

/// Drift's own package. Its foreground time is idle, never drift.
const driftPackage = 'io.github.santhoshunt.drift';

/// Everything screens need that lives outside Flutter: the database, the
/// Android bridges and the clock. Provided once at the top of the widget
/// tree; tests build one from fakes with [AppServices.new].
class AppServices {
  AppServices({
    required this.db,
    required this.usage,
    required this.icons,
    required this.clock,
  }) : events = EventRepository(db),
       sessions = SessionRepository(db),
       plans = PlanRepository(db),
       rules = RuleRepository(db),
       apps = AppRepository(db),
       meta = MetaRepository(db) {
    ingestor = Ingestor(
      source: usage,
      events: events,
      sessions: sessions,
      plans: plans,
      apps: apps,
      meta: meta,
      clock: clock,
      extraIdlePackages: const {driftPackage, 'com.android.systemui'},
    );
  }

  /// The real services on a phone.
  static Future<AppServices> open() async => AppServices(
    db: await openDriftDb(),
    usage: const ChannelUsageSource(),
    icons: const ChannelIconSwitcher(),
    clock: SystemClock(),
  );

  final Database db;
  final UsageSource usage;
  final IconSwitcher icons;
  final Clock clock;
  final EventRepository events;
  final SessionRepository sessions;
  final PlanRepository plans;
  final RuleRepository rules;
  final AppRepository apps;
  final MetaRepository meta;
  late final Ingestor ingestor;

  /// Bumped after anything that changes what a day looks like: an ingest,
  /// a plan edit or an answered question. Screens listen and reload.
  final ValueNotifier<int> revision = ValueNotifier(0);

  void bump() => revision.value++;

  Future<IngestResult?>? _running;

  /// Runs one ingest unless one is already running, then bumps
  /// [revision]. A failure is logged and swallowed: the screens still show
  /// what is already stored, and the next resume tries again.
  Future<IngestResult?> ingest() => _running ??= _ingest().whenComplete(() {
    _running = null;
  });

  Future<IngestResult?> _ingest() async {
    try {
      final result = await ingestor.run();
      bump();
      return result;
    } catch (e, st) {
      debugPrint('Ingest failed: $e\n$st');
      return null;
    }
  }
}
