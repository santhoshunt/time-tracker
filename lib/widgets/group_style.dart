import 'package:flutter/material.dart';

import '../domain/app_groups.dart';
import '../theme/drift_theme.dart';

/// Names for the ten group colours, in [AppGroup.colorIdx] order; screen
/// readers say them on the editor's swatches.
const groupColorNames = [
  'Sky', 'Violet', 'Teal', 'Pink', 'Coral',
  'Sand', 'Lime', 'Blue', 'Yellow', 'Lavender',
];

const _dark = [
  Color(0xFF38BDF8), Color(0xFF9B8CFF), Color(0xFF4CC9C0), Color(0xFFF28CB8), Color(0xFFFF8A65),
  Color(0xFFD9B98C), Color(0xFFB5D46A), Color(0xFF74A7FF), Color(0xFFFFC857), Color(0xFFC0A6E8),
];

const _light = [
  Color(0xFF0E86C4), Color(0xFF6A55D8), Color(0xFF13998C), Color(0xFFC94C86), Color(0xFFD0582E),
  Color(0xFFA07A40), Color(0xFF6E8F22), Color(0xFF3B6FD8), Color(0xFFB8860B), Color(0xFF8A6BC0),
];

/// A group's colour: darker on the light themes so a 1.5 px outline still
/// reads on white. Only outlines, rings and borders use it; text stays in
/// the theme's colours.
Color groupColor(BuildContext context, int idx) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final list = dark ? _dark : _light;
  return list[idx.clamp(0, list.length - 1)];
}

/// The emoji grid in the group editor (option C: a grid, or type your
/// own): work, study, play, chat and rest. The first is the default.
const groupEmojis = [
  '💼', '📚', '💻', '✏️', '🧠', '📊', '🎯', '🛠️', '🎨', '🎵', '🎧', '📷',
  '🎮', '🕹️', '📱', '🎬', '📺', '💬', '📰', '🔥', '🛒', '💰', '🗺️', '✈️',
  '🏋️', '🧘', '🏃', '🍳', '☕', '🌱', '🌙', '🏠', '❤️', '⏰', '🧩', '🙂',
];

/// Whether [text] is a single emoji's worth: one character as the user
/// sees it, so flags and joined emoji count as one.
bool isSingleGrapheme(String text) => text.trim().characters.length == 1;

/// A group as a pill (chips option A): its emoji and name inside a 1.5 px
/// outline in the group's colour. Selected adds a light tint of the colour
/// behind the theme's text and a check, so the words never sit in colour.
class GroupChip extends StatelessWidget {
  const GroupChip({
    super.key,
    required this.group,
    this.selected = false,
    this.onTap,
    this.onDeleted,
  });

  final AppGroup group;
  final bool selected;
  final VoidCallback? onTap;

  /// Shows a close button that calls this, for chips on a block.
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final color = groupColor(context, group.colorIdx);
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(color: c.text);
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: '${group.name} group, ${group.apps.length} apps',
      excludeSemantics: true,
      child: Material(
        color: selected ? Color.alphaBlend(color.withValues(alpha: 0.15), c.card) : c.card,
        shape: StadiumBorder(side: BorderSide(color: color, width: 1.5)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.fromLTRB(10, 6, onDeleted == null ? 12 : 4, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(Icons.check, size: 16, color: c.text),
                  const SizedBox(width: 4),
                ],
                Text(group.emoji, textScaler: TextScaler.noScaling, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(group.name, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (onDeleted != null)
                  InkResponse(
                    onTap: onDeleted,
                    radius: 16,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(Icons.close, size: 16, color: c.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
