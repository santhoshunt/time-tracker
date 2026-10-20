import 'models.dart';

/// What a group's apps are to Sandy: help or distraction. Stored as the
/// enum name in `app_groups.kind`.
enum GroupKind {
  productive,
  distracting;

  static GroupKind fromKey(String? key) =>
      key == 'distracting' ? GroupKind.distracting : GroupKind.productive;
}

/// A named set of apps with an emoji and a colour (index into
/// groupColor's list), picked as one in a block's app picker.
class AppGroup {
  const AppGroup({
    this.id,
    required this.name,
    required this.emoji,
    required this.colorIdx,
    required this.kind,
    required this.apps,
  });

  final int? id;
  final String name;
  final String emoji;
  final int colorIdx;
  final GroupKind kind;
  final Set<String> apps;

  AppGroup copyWith({
    int? id,
    String? name,
    String? emoji,
    int? colorIdx,
    GroupKind? kind,
    Set<String>? apps,
  }) => AppGroup(
    id: id ?? this.id,
    name: name ?? this.name,
    emoji: emoji ?? this.emoji,
    colorIdx: colorIdx ?? this.colorIdx,
    kind: kind ?? this.kind,
    apps: apps ?? this.apps,
  );
}

/// Every group and which blocks use them, loaded once per screen or run and
/// handed to the classifier, the nudge windows and the distracting count.
///
/// Groups are linked: a block that uses a group follows later edits to it,
/// because nothing is copied into `app_rules`.
class AppGroups {
  const AppGroups({this.groups = const [], this.byBlock = const {}});

  /// No groups at all: the classifier behaves as it did before v0.7.0.
  static const none = AppGroups();

  final List<AppGroup> groups;

  /// Block name key (as [blockKey] makes it) to group id to verdict.
  final Map<String, Map<int, Verdict>> byBlock;

  /// The verdict a block's chosen groups give [p], or null when none of
  /// them holds it. Off wins over on: when two groups a block uses
  /// disagree, the cautious answer is drift.
  Verdict? blockVerdict(String key, String p) {
    final chosen = byBlock[key];
    if (chosen == null || chosen.isEmpty) return null;
    Verdict? out;
    for (final g in groups) {
      final v = chosen[g.id];
      if (v == null || !g.apps.contains(p)) continue;
      if (v == Verdict.offTrack) return Verdict.offTrack;
      out = v;
    }
    return out;
  }

  /// Apps in any Distracting group.
  Set<String> get distractingApps => {
    for (final g in groups)
      if (g.kind == GroupKind.distracting) ...g.apps,
  };

  /// Apps in any Productive group.
  Set<String> get productiveApps => {
    for (final g in groups)
      if (g.kind == GroupKind.productive) ...g.apps,
  };

  bool isDistractingMember(String p) => groups.any(
    (g) => g.kind == GroupKind.distracting && g.apps.contains(p),
  );

  /// The groups [key]'s block uses with [verdict], by id.
  Set<int> forBlock(String key, Verdict verdict) => {
    for (final MapEntry(key: id, :value) in (byBlock[key] ?? const <int, Verdict>{}).entries)
      if (value == verdict) id,
  };
}
