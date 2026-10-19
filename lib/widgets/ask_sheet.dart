import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_services.dart';
import '../domain/models.dart';
import '../platform/usage_source.dart';
import '../screens/block_editor_screen.dart';
import '../services/day_loader.dart';
import '../theme/drift_theme.dart';

/// Launcher icons by package for the ask sheet and the Learned rules list,
/// kept for the life of the process so Android is asked once per app.
final _iconCache = <String, Future<Uint8List?>>{};

/// The launcher icon of [p], or null when Android has none. Cached.
Future<Uint8List?> cachedAppIcon(AppServices services, String p) =>
    _iconCache.putIfAbsent(p, () async {
      try {
        final bytes = await services.usage.appIcon(p);
        return bytes == null ? null : Uint8List.fromList(bytes);
      } catch (_) {
        return null;
      }
    });

/// What an Android category is called in the guess line.
String categoryWord(String category) => switch (category) {
  AppCategories.game => 'game',
  AppCategories.video => 'video',
  AppCategories.social => 'social',
  AppCategories.news => 'news',
  AppCategories.audio => 'music',
  AppCategories.image => 'photos',
  AppCategories.maps => 'maps',
  AppCategories.productivity => 'productivity',
  AppCategories.accessibility => 'accessibility',
  _ => "doesn't say",
};

/// "Guess: off track. Android lists it as social." For an app with no
/// category: "Guess: on track. Android doesn't say what kind of app it is."
String guessLine(Verdict guess, String category) {
  final verdict = guess == Verdict.guessedOff ? 'off track' : 'on track';
  final word = categoryWord(category);
  final reason = word == "doesn't say"
      ? "Android doesn't say what kind of app it is."
      : 'Android lists it as $word.';
  return 'Guess: $verdict. $reason';
}

/// The user's answer to one ask sheet.
class AskAnswer {
  const AskAnswer({required this.verdict, required this.remember});

  /// [Verdict.onTrack] or [Verdict.offTrack].
  final Verdict verdict;

  /// True writes a rule for every block with this name; false writes an
  /// override for today's sessions only.
  final bool remember;
}

/// Asks about every guessed (block, app) pair in [day], oldest first, one
/// bottom sheet at a time, and returns how many were answered.
///
/// Each answer is stored before the next sheet opens. Closing a sheet
/// without answering stops the queue; the rest are asked on the next
/// launch or resume.
Future<int> showAskQueue(
  BuildContext context,
  AppServices services,
  DayData day,
) async {
  final queue = [...day.unanswered]..sort((a, b) => a.start.compareTo(b.start));
  if (queue.isEmpty) return 0;
  final categories = await services.apps.categoryMap();
  var answered = 0;
  for (final segment in queue) {
    if (!context.mounted) break;
    final done = await showAskSheet(
      context,
      services,
      day,
      segment,
      category: categories[segment.p] ?? AppCategories.undefined,
    );
    if (!done) break;
    answered++;
  }
  return answered;
}

/// Shows the ask sheet for [segment], a guessed slice of [day], and stores
/// the answer. Returns false when the sheet was closed without one.
///
/// [category] is the app's Android category; it is read from the apps
/// table when not given.
Future<bool> showAskSheet(
  BuildContext context,
  AppServices services,
  DayData day,
  Segment segment, {
  String? category,
}) async {
  final p = segment.p;
  final blockName = segment.blockName;
  if (p == null || blockName == null) return false;
  final cat =
      category ??
      (await services.apps.categoryMap())[p] ??
      AppCategories.undefined;
  if (!context.mounted) return false;

  final answer = await showModalBottomSheet<AskAnswer>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => AskSheet(
      appLabel: day.labelOf(p),
      blockName: blockName,
      start: segment.start,
      end: segment.end,
      guess: segment.verdict,
      category: cat,
      icon: AppIcon(
        package: p,
        label: day.labelOf(p),
        size: 44,
        iconFor: (p) => cachedAppIcon(services, p),
      ),
    ),
  );
  if (answer == null) return false;

  final rules = services.rules;
  if (answer.remember) {
    await rules.upsertRule(blockName, p, answer.verdict, services.clock.now());
  } else {
    final key = blockKey(blockName);
    final ids = <int>{
      for (final s in day.segments)
        if (s.p == p &&
            s.sessionId != null &&
            s.blockName != null &&
            blockKey(s.blockName!) == key)
          s.sessionId!,
    };
    for (final id in ids) {
      await rules.setOverride(id, answer.verdict);
    }
  }
  services.bump();
  return true;
}

/// Ask option A: "WhatsApp during Deep work?" with the time it was used,
/// the category guess, On track and Off track, and "Remember for every
/// Deep work", checked by default. Pops with an [AskAnswer].
class AskSheet extends StatefulWidget {
  const AskSheet({
    super.key,
    required this.appLabel,
    required this.blockName,
    required this.start,
    required this.end,
    required this.guess,
    required this.category,
    required this.icon,
  });

  final String appLabel;
  final String blockName;
  final DateTime start;
  final DateTime end;

  /// [Verdict.guessedOn] or [Verdict.guessedOff].
  final Verdict guess;
  final String category;
  final Widget icon;

  @override
  State<AskSheet> createState() => _AskSheetState();
}

class _AskSheetState extends State<AskSheet> {
  bool _remember = true;
  bool _answered = false;

  void _answer(Verdict v) {
    if (_answered) return;
    setState(() => _answered = true);
    Navigator.of(context).pop(AskAnswer(verdict: v, remember: _remember));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    final text = Theme.of(context).textTheme;
    final time = DateFormat('HH:mm');
    final panel = Color.alphaBlend(c.text.withValues(alpha: 0.05), c.card);

    final content = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              widget.icon,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${widget.appLabel} during ${widget.blockName}?',
                      style: text.titleLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Used ${time.format(widget.start)} to ${time.format(widget.end)}',
                      style: text.bodyMedium?.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 11, 14, 11),
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.lightbulb_outline,
                    size: 18,
                    color: c.guessed,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    guessLine(widget.guess, widget.category),
                    style: text.bodyMedium?.copyWith(color: c.text),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _VerdictButton(
                  label: 'On track',
                  icon: Icons.check_circle_outline,
                  color: c.onTrack,
                  onPressed: _answered ? null : () => _answer(Verdict.onTrack),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _VerdictButton(
                  label: 'Off track',
                  icon: Icons.do_not_disturb_on_outlined,
                  color: c.offTrack,
                  onPressed: _answered ? null : () => _answer(Verdict.offTrack),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          MergeSemantics(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _remember = !_remember),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Compact, so the box lines up with the content edge
                    // and the first line of the label.
                    Checkbox(
                      value: _remember,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) => setState(() => _remember = v ?? true),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          Text(
                            'Remember for every ${widget.blockName}',
                            style: text.bodyLarge?.copyWith(color: c.text),
                          ),
                          Text(
                            _remember
                                ? 'Drift stops asking about '
                                      '${widget.appLabel} in ${widget.blockName}.'
                                : 'Applies to today only. Drift asks again '
                                      'next time.',
                            style: text.bodySmall?.copyWith(
                              color: c.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    // useSafeArea keeps the sheet clear of the top only; this keeps the
    // last row clear of the gesture bar.
    return SafeArea(top: false, child: content);
  }
}

class _VerdictButton extends StatelessWidget {
  const _VerdictButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.drift;
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        side: BorderSide(color: color.withValues(alpha: 0.7), width: 1.5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 20, color: color),
      label: Text(label, maxLines: 1, softWrap: false),
    );
  }
}
