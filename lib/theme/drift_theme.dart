import 'package:flutter/material.dart';

import 'theme_id.dart';

/// The colour tokens every Drift screen paints with, one set per [ThemeId].
/// Widgets read them through `context.drift` instead of the Material
/// ColorScheme, so charts and plan blocks use the same names as the plan.
///
/// Rule for all of them: text on a coloured fill is [text], [bg] or
/// [onAccent], never another coloured token.
@immutable
class DriftColors extends ThemeExtension<DriftColors> {
  const DriftColors({
    required this.bg,
    required this.card,
    required this.line,
    required this.text,
    required this.textSecondary,
    required this.accent,
    required this.onAccent,
    required this.onTrack,
    required this.offTrack,
    required this.guessed,
  });

  /// The token table from the plan, one row per theme.
  factory DriftColors.of(ThemeId id) => switch (id) {
    ThemeId.mono => const DriftColors(
      bg: Color(0xFF101214),
      card: Color(0xFF181B1E),
      line: Color(0xFF272B30),
      text: Color(0xFFF0F4FF),
      textSecondary: Color(0xFFAAB8D4),
      accent: Color(0xFFE6EAF2),
      onAccent: Color(0xFF101214),
      onTrack: Color(0xFF3DD68C),
      offTrack: Color(0xFFFF6B6B),
      guessed: Color(0xFFF5B544),
    ),
    ThemeId.blackCyan => const DriftColors(
      bg: Color(0xFF000000),
      card: Color(0xFF0D0F12),
      line: Color(0xFF1E2328),
      text: Color(0xFFF0F4FF),
      textSecondary: Color(0xFFAAB8D4),
      accent: Color(0xFF38BDF8),
      onAccent: Color(0xFF000000),
      onTrack: Color(0xFF3DD68C),
      offTrack: Color(0xFFFF6B6B),
      guessed: Color(0xFFF5B544),
    ),
    ThemeId.cleanLight => const DriftColors(
      bg: Color(0xFFF7F8FA),
      card: Color(0xFFFFFFFF),
      line: Color(0xFFE3E7ED),
      text: Color(0xFF1B1F24),
      textSecondary: Color(0xFF5F6B7A),
      accent: Color(0xFF4A90E2),
      onAccent: Color(0xFFFFFFFF),
      onTrack: Color(0xFF2E9E6B),
      offTrack: Color(0xFFE0504E),
      guessed: Color(0xFFF2B544),
    ),
    ThemeId.warmPaper => const DriftColors(
      bg: Color(0xFFFBF7F2),
      card: Color(0xFFFFFFFF),
      line: Color(0xFFEADFD3),
      text: Color(0xFF2B2420),
      textSecondary: Color(0xFF7A6A5E),
      accent: Color(0xFFD9733B),
      onAccent: Color(0xFFFFFFFF),
      onTrack: Color(0xFF5B9A68),
      offTrack: Color(0xFFC8553D),
      guessed: Color(0xFFD9A23B),
    ),
  };

  /// Screen background.
  final Color bg;

  /// Cards, sheets and the navigation bar.
  final Color card;

  /// Hairline borders and dividers.
  final Color line;

  /// Primary text.
  final Color text;

  /// Captions, hints and unselected labels.
  final Color textSecondary;

  /// Selection, filled buttons and the plan-block outline.
  final Color accent;

  /// Text and icons on an [accent] fill: the background colour in the dark
  /// themes (their accent is light) and white in the light themes.
  final Color onAccent;

  /// Time spent on a planned app.
  final Color onTrack;

  /// Time spent on an app outside the plan.
  final Color offTrack;

  /// Time whose verdict comes from the category guess, not a rule.
  final Color guessed;

  /// Idle time inside a block. It counts as on track, so it is the on-track
  /// colour at low strength.
  Color get idleFill => onTrack.withValues(alpha: 0.22);

  /// Time on an app answered Neutral: fine in that block, neither on nor
  /// off track, so grey. Solid, unlike the faint grey of time outside the
  /// plan, and dark enough under a [bg] label in every theme.
  Color get neutral => textSecondary;

  /// The fill of a plan block, as in the mockups.
  Color get planFill => accent.withValues(alpha: 0.13);

  /// The border of a plan block, as in the mockups.
  Color get planBorder => accent.withValues(alpha: 0.45);

  @override
  DriftColors copyWith({
    Color? bg,
    Color? card,
    Color? line,
    Color? text,
    Color? textSecondary,
    Color? accent,
    Color? onAccent,
    Color? onTrack,
    Color? offTrack,
    Color? guessed,
  }) => DriftColors(
    bg: bg ?? this.bg,
    card: card ?? this.card,
    line: line ?? this.line,
    text: text ?? this.text,
    textSecondary: textSecondary ?? this.textSecondary,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    onTrack: onTrack ?? this.onTrack,
    offTrack: offTrack ?? this.offTrack,
    guessed: guessed ?? this.guessed,
  );

  @override
  DriftColors lerp(covariant DriftColors? other, double t) {
    if (other == null) return this;
    return DriftColors(
      bg: Color.lerp(bg, other.bg, t)!,
      card: Color.lerp(card, other.card, t)!,
      line: Color.lerp(line, other.line, t)!,
      text: Color.lerp(text, other.text, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      onTrack: Color.lerp(onTrack, other.onTrack, t)!,
      offTrack: Color.lerp(offTrack, other.offTrack, t)!,
      guessed: Color.lerp(guessed, other.guessed, t)!,
    );
  }
}

/// Mono and Black and cyan are dark; Clean light and Warm paper are light.
/// The choice is fixed per theme; Drift never follows the system setting.
Brightness driftBrightness(ThemeId id) => switch (id) {
  ThemeId.mono || ThemeId.blackCyan => Brightness.dark,
  ThemeId.cleanLight || ThemeId.warmPaper => Brightness.light,
};

/// The full Material 3 theme for [id]. Every ColorScheme role is filled in,
/// because M3 widgets read roles that a plain `primary` does not cover
/// (the navigation bar reads surfaceContainer, the segmented button
/// secondaryContainer, the snackbar inverseSurface). Tinted containers are
/// opaque blends of the accent over the card, and their text is [text], so
/// no screen ends up with coloured text on a coloured fill.
ThemeData buildDriftTheme(ThemeId id) {
  final c = DriftColors.of(id);
  final brightness = driftBrightness(id);
  final tint = Color.alphaBlend(c.accent.withValues(alpha: 0.13), c.card);
  final errorTint = Color.alphaBlend(c.offTrack.withValues(alpha: 0.13), c.card);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    primaryContainer: tint,
    onPrimaryContainer: c.text,
    secondary: c.accent,
    onSecondary: c.onAccent,
    secondaryContainer: tint,
    onSecondaryContainer: c.text,
    tertiary: c.accent,
    onTertiary: c.onAccent,
    tertiaryContainer: tint,
    onTertiaryContainer: c.text,
    error: c.offTrack,
    onError: c.onAccent,
    errorContainer: errorTint,
    onErrorContainer: c.text,
    surface: c.bg,
    onSurface: c.text,
    onSurfaceVariant: c.textSecondary,
    surfaceDim: c.bg,
    surfaceBright: c.card,
    surfaceContainerLowest: c.card,
    surfaceContainerLow: c.card,
    surfaceContainer: c.card,
    surfaceContainerHigh: c.card,
    surfaceContainerHighest: c.card,
    outline: c.line,
    outlineVariant: c.line,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: c.text,
    onInverseSurface: c.bg,
    inversePrimary: c.bg,
    surfaceTint: Colors.transparent,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'Roboto',
  );
  // ThemeData keeps sizes out of its textTheme and merges them in only when
  // the Theme widget builds. Merging the geometry here gives the component
  // styles below (app bar title, navigation labels) their real sizes.
  final geometry = Typography.material2021(
    platform: TargetPlatform.android,
  ).englishLike;
  final textTheme = _onlyRegularAndMedium(
    geometry.merge(base.textTheme).apply(
      fontFamily: 'Roboto',
      bodyColor: c.text,
      displayColor: c.text,
    ),
  );

  const cardRadius = BorderRadius.all(Radius.circular(14));
  const buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
  );
  final hairline = BorderSide(color: c.line);
  final labelStyle = textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500);
  final navIndicator = Color.alphaBlend(
    c.accent.withValues(alpha: 0.16),
    c.card,
  );

  return base.copyWith(
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    cardColor: c.card,
    dividerColor: c.line,
    hintColor: c.textSecondary,
    textTheme: textTheme,
    primaryTextTheme: textTheme.apply(
      bodyColor: c.onAccent,
      displayColor: c.onAccent,
    ),
    iconTheme: IconThemeData(color: c.text),
    extensions: [c],
    appBarTheme: AppBarThemeData(
      backgroundColor: c.bg,
      foregroundColor: c.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: c.card,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: cardRadius, side: hairline),
    ),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    // No textColor here: ListTile applies it to the subtitle as well, which
    // would override the secondary colour below.
    listTileTheme: ListTileThemeData(
      iconColor: c.textSecondary,
      titleTextStyle: textTheme.bodyLarge,
      subtitleTextStyle: textTheme.bodyMedium?.copyWith(
        color: c.textSecondary,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.card,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      indicatorColor: navIndicator,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? c.accent
              : c.textSecondary,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? c.accent
              : c.textSecondary,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        disabledBackgroundColor: c.line,
        disabledForegroundColor: c.textSecondary,
        textStyle: labelStyle,
        shape: buttonShape,
        minimumSize: const Size(64, 48),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: c.card,
        foregroundColor: c.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        side: hairline,
        textStyle: labelStyle,
        shape: buttonShape,
        minimumSize: const Size(64, 48),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        side: hairline,
        textStyle: labelStyle,
        shape: buttonShape,
        minimumSize: const Size(64, 48),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        textStyle: labelStyle,
        shape: buttonShape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.text),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? c.onAccent : c.textSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.accent : c.line,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : c.textSecondary.withValues(alpha: 0.5),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? c.accent : c.textSecondary,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? c.accent : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(c.onAccent),
      side: BorderSide(color: c.textSecondary, width: 2),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? c.accent : c.card,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? c.onAccent : c.text,
        ),
        iconColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? c.onAccent : c.text,
        ),
        side: WidgetStatePropertyAll(hairline),
        textStyle: WidgetStatePropertyAll(labelStyle),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.line,
      circularTrackColor: c.line,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.card,
      modalBackgroundColor: c.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      dragHandleColor: c.textSecondary.withValues(alpha: 0.5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        side: hairline,
      ),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.card,
      surfaceTintColor: Colors.transparent,
      textStyle: textTheme.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: hairline,
      ),
    ),
    // Accent-tinted, matching the app toast (Sandy's pick B): an inverted
    // white bar looked foreign on the dark themes.
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Color.alphaBlend(c.accent.withValues(alpha: 0.12), c.card),
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: c.text),
      actionTextColor: c.accent,
      closeIconColor: c.textSecondary,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        side: BorderSide(color: c.accent.withValues(alpha: 0.45)),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: c.card,
      labelStyle: TextStyle(color: c.textSecondary),
      hintStyle: TextStyle(color: c.textSecondary),
      border: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        borderSide: hairline,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        borderSide: hairline,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: c.accent, width: 2),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.3),
      selectionHandleColor: c.accent,
    ),
  );
}

/// Drift bundles only Roboto 400 and 500, so every style is clamped to
/// those two weights. A heavier request would otherwise be synthesised.
TextTheme _onlyRegularAndMedium(TextTheme t) {
  TextStyle? clamp(TextStyle? s) {
    if (s == null) return null;
    final w = s.fontWeight ?? FontWeight.w400;
    return s.copyWith(
      fontWeight: w.value > 400 ? FontWeight.w500 : FontWeight.w400,
    );
  }

  return t.copyWith(
    displayLarge: clamp(t.displayLarge),
    displayMedium: clamp(t.displayMedium),
    displaySmall: clamp(t.displaySmall),
    headlineLarge: clamp(t.headlineLarge),
    headlineMedium: clamp(t.headlineMedium),
    headlineSmall: clamp(t.headlineSmall),
    titleLarge: clamp(t.titleLarge),
    titleMedium: clamp(t.titleMedium),
    titleSmall: clamp(t.titleSmall),
    bodyLarge: clamp(t.bodyLarge),
    bodyMedium: clamp(t.bodyMedium),
    bodySmall: clamp(t.bodySmall),
    labelLarge: clamp(t.labelLarge),
    labelMedium: clamp(t.labelMedium),
    labelSmall: clamp(t.labelSmall),
  );
}

/// Shorthand for the active theme's tokens: `context.drift.accent`.
extension DriftThemeX on BuildContext {
  DriftColors get drift => Theme.of(this).extension<DriftColors>()!;
}
