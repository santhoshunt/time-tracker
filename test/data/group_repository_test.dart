import 'package:drift_time/app_services.dart';
import 'package:drift_time/domain/app_groups.dart';
import 'package:drift_time/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  late AppServices s;

  setUp(() async => s = await testServices());
  tearDown(() => s.db.close());

  const sinks = AppGroup(
    name: 'Time sinks',
    emoji: 'g',
    colorIdx: 4,
    kind: GroupKind.distracting,
    apps: {'com.example.video', 'com.example.social'},
  );

  test('save inserts, then updates and replaces the apps', () async {
    final id = await s.groups.save(sinks);
    var all = await s.groups.all();
    expect(all.single.id, id);
    expect(all.single.kind, GroupKind.distracting);
    expect(all.single.apps, {'com.example.video', 'com.example.social'});

    await s.groups.save(all.single.copyWith(name: 'Sinks', colorIdx: 2, apps: {'com.example.game'}));
    all = await s.groups.all();
    expect(all.single.name, 'Sinks');
    expect(all.single.colorIdx, 2);
    expect(all.single.apps, {'com.example.game'});
  });

  test('groups list in the order they were made', () async {
    await s.groups.save(sinks.copyWith(name: 'B'));
    await s.groups.save(sinks.copyWith(name: 'A'));
    expect((await s.groups.all()).map((g) => g.name), ['B', 'A']);
  });

  test('delete takes the apps and every block link with it', () async {
    final id = await s.groups.save(sinks);
    await s.groups.setForBlock('Deep work', {id: Verdict.offTrack});
    await s.groups.delete(id);
    expect(await s.groups.all(), isEmpty);
    expect(await s.db.query('app_group_members'), isEmpty);
    expect(await s.db.query('block_groups'), isEmpty);
  });

  test('block links are keyed like rules and replaced as a whole', () async {
    final a = await s.groups.save(sinks);
    final b = await s.groups.save(sinks.copyWith(name: 'Work', kind: GroupKind.productive));
    await s.groups.setForBlock('Deep work ', {a: Verdict.offTrack, b: Verdict.onTrack});
    expect(await s.groups.forBlock('deep work'), {a: Verdict.offTrack, b: Verdict.onTrack});
    await s.groups.setForBlock('Deep work', {b: Verdict.onTrack});
    expect(await s.groups.forBlock('Deep work'), {b: Verdict.onTrack});
  });

  test('a rename moves the links, or copies them when the old name stays', () async {
    final a = await s.groups.save(sinks);
    await s.groups.setForBlock('Deep work', {a: Verdict.offTrack});
    await s.groups.moveBlock('Deep work', 'Focus', keepOld: true);
    expect(await s.groups.forBlock('Deep work'), {a: Verdict.offTrack});
    expect(await s.groups.forBlock('Focus'), {a: Verdict.offTrack});
    await s.groups.moveBlock('Focus', 'Study', keepOld: false);
    expect(await s.groups.forBlock('Focus'), isEmpty);
    expect(await s.groups.forBlock('Study'), {a: Verdict.offTrack});
  });

  test('snapshot holds the groups and the block links', () async {
    expect(identical(await s.groups.snapshot(), AppGroups.none), isTrue);
    final a = await s.groups.save(sinks);
    await s.groups.setForBlock('Deep work', {a: Verdict.offTrack});
    final snap = await s.groups.snapshot();
    expect(snap.groups.single.name, 'Time sinks');
    expect(snap.byBlock, {'deep work': {a: Verdict.offTrack}});
    expect(snap.isDistractingMember('com.example.video'), isTrue);
  });
}
