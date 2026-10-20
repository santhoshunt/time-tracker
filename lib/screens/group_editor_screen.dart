import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../domain/app_groups.dart';
import '../domain/models.dart';
import '../theme/drift_theme.dart';
import '../widgets/group_style.dart';
import '../widgets/undo_snackbar.dart';
import 'block_editor_screen.dart' show AppIcon, AppPickerSheet;

/// Creating or editing an app group (editor option A, a full page): the
/// emoji tile and name, ten colour swatches, Productive or Distracting, and
/// the apps. Saving bumps the app's revision, so every block that uses the
/// group (linked) judges by the new apps at once.
class GroupEditorScreen extends StatefulWidget {
  const GroupEditorScreen({super.key, this.group});

  /// The group to edit, or null for a new one.
  final AppGroup? group;

  @override
  State<GroupEditorScreen> createState() => _GroupEditorScreenState();
}

class _GroupEditorScreenState extends State<GroupEditorScreen> {
  late final AppServices _services = context.read<AppServices>();
  late final _name = TextEditingController(text: widget.group?.name ?? '');
  late String _emoji = widget.group?.emoji ?? groupEmojis.first;
  late int _colorIdx = widget.group?.colorIdx ?? 0;
  late GroupKind _kind = widget.group?.kind ?? GroupKind.productive;
  late final Set<String> _apps = {...?widget.group?.apps};
  List<AppInfo> _all = const [];
  bool _submitted = false;
  final _icons = <String, Future<Uint8List?>>{};

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {
    var apps = await _services.apps.all();
    if (apps.isEmpty) {
      try {
        apps = [for (final m in await _services.usage.listApps()) ?AppInfo.fromMap(m)]
          ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      } catch (_) {
        apps = const [];
      }
    }
    if (mounted) setState(() => _all = apps);
  }

  Future<Uint8List?> _iconFor(String p) => _icons.putIfAbsent(p, () async {
    try {
      final bytes = await _services.usage.appIcon(p);
      return bytes == null ? null : Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  });

  String _labelOf(String p) {
    for (final a in _all) {
      if (a.p == p) return a.label;
    }
    return p;
  }

  String? get _nameError => _submitted && _name.text.trim().isEmpty ? 'Enter a name' : null;

  String? get _appsError => _submitted && _apps.isEmpty ? 'Pick at least one app' : null;

  Future<void> _pickEmoji() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => EmojiSheet(current: _emoji),
    );
    if (picked != null) setState(() => _emoji = picked);
  }

  Future<void> _pickApps() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => AppPickerSheet(
        title: 'Apps in this group',
        apps: _all,
        selected: _apps,
        otherSelected: const {},
        otherLabel: '',
        iconFor: _iconFor,
        onChanged: (p, on) => setState(() => on ? _apps.add(p) : _apps.remove(p)),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _submitted = true);
    if (_nameError != null || _appsError != null) return;
    final group = AppGroup(
      id: widget.group?.id,
      name: _name.text.trim(),
      emoji: _emoji,
      colorIdx: _colorIdx,
      kind: _kind,
      apps: {..._apps},
    );
    await _services.groups.save(group);
    _services.bump();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final group = widget.group!;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${group.name}"?'),
        content: const Text('Blocks that use it keep their own app rules.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _services.groups.delete(group.id!);
    _services.bump();
    showAppToastOn(messenger, 'Deleted "${group.name}"', tone: AppToastTone.removal);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final color = groupColor(context, _colorIdx);
    final label = text.titleSmall?.copyWith(color: c.text);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.group == null ? 'New group' : 'Edit group'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                button: true,
                label: 'Icon $_emoji, change it',
                excludeSemantics: true,
                child: Material(
                  color: c.card,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: color, width: 2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const ValueKey('groupEmojiTile'),
                    onTap: _pickEmoji,
                    child: SizedBox.square(
                      dimension: 56,
                      child: Center(
                        child: Text(_emoji, textScaler: TextScaler.noScaling, style: const TextStyle(fontSize: 28)),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) {
                    if (_submitted) setState(() {});
                  },
                  decoration: InputDecoration(
                    labelText: 'Group name',
                    hintText: 'Work apps',
                    errorText: _nameError,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text('Colour', style: label),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              for (var i = 0; i < groupColorNames.length; i++)
                Semantics(
                  label: '${groupColorNames[i]} colour',
                  selected: i == _colorIdx,
                  button: true,
                  excludeSemantics: true,
                  child: GestureDetector(
                    onTap: () => setState(() => _colorIdx = i),
                    child: Container(
                      width: 36,
                      height: 36,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: i == _colorIdx ? c.text : Colors.transparent, width: 2),
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(shape: BoxShape.circle, color: groupColor(context, i)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Text('These apps are', style: label),
          const SizedBox(height: 10),
          SegmentedButton<GroupKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: GroupKind.productive, label: Text('Productive')),
              ButtonSegment(value: GroupKind.distracting, label: Text('Distracting')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 6),
          Text(
            _kind == GroupKind.distracting
                ? 'Count as drift in every block that does not allow this group, and as distracting time in your notifications.'
                : 'Never count as distracting time. Pick the group in a block to make its apps on track there.',
            style: text.bodySmall?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: 22),
          Text('Apps (${_apps.length})', style: label),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _apps)
                InputChip(
                  avatar: AppIcon(package: p, label: _labelOf(p), size: 22, iconFor: _iconFor),
                  label: Text(_labelOf(p)),
                  labelStyle: text.labelLarge?.copyWith(color: c.text),
                  backgroundColor: c.card,
                  side: BorderSide(color: c.line),
                  shape: const StadiumBorder(),
                  deleteIcon: Icon(Icons.close, size: 16, color: c.textSecondary),
                  deleteButtonTooltipMessage: 'Remove',
                  onDeleted: () => setState(() => _apps.remove(p)),
                ),
              ActionChip(
                avatar: Icon(Icons.add, size: 18, color: c.textSecondary),
                label: const Text('Choose apps'),
                labelStyle: text.labelLarge?.copyWith(color: c.text),
                backgroundColor: c.bg,
                side: BorderSide(color: _appsError == null ? c.line : c.offTrack),
                shape: const StadiumBorder(),
                onPressed: _pickApps,
              ),
            ],
          ),
          if (_appsError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_appsError!, style: text.bodySmall?.copyWith(color: c.offTrack)),
            ),
          if (widget.group != null) ...[
            const SizedBox(height: 32),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _delete,
                icon: Icon(Icons.delete_outline, color: c.offTrack),
                label: Text('Delete group', style: TextStyle(color: c.offTrack)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The emoji picker (option C): a grid of [groupEmojis], and a field that
/// takes any one emoji from the keyboard.
class EmojiSheet extends StatefulWidget {
  const EmojiSheet({super.key, required this.current});

  final String current;

  @override
  State<EmojiSheet> createState() => _EmojiSheetState();
}

class _EmojiSheetState extends State<EmojiSheet> {
  final _own = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  void _useOwn() {
    final v = _own.text.trim();
    if (!isSingleGrapheme(v)) {
      setState(() => _error = 'Type one emoji');
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Pick an icon', style: text.titleMedium),
            const SizedBox(height: 10),
            GridView.count(
              crossAxisCount: 6,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final e in groupEmojis)
                  InkResponse(
                    key: ValueKey('emoji-$e'),
                    onTap: () => Navigator.pop(context, e),
                    radius: 24,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: e == widget.current
                            ? BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: c.accent, width: 2),
                              )
                            : null,
                        child: Text(e, textScaler: TextScaler.noScaling, style: const TextStyle(fontSize: 24)),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('ownEmoji'),
                    controller: _own,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _useOwn(),
                    decoration: InputDecoration(
                      labelText: 'Type your own',
                      hintText: 'One emoji',
                      errorText: _error,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton(onPressed: _useOwn, child: const Text('Use')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
