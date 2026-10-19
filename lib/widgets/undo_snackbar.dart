import 'package:flutter/material.dart';

/// Tones for [showAppToast]: each picks the icon's tint and a fallback icon.
/// Call sites pass the operation's own icon; the tone says what kind of
/// outcome it was: [change] edits (accent), [removal] deletes and discards
/// (the error colour), [success] confirmations and saves (green).
enum AppToastTone { success, change, removal, error, info }

/// The app's toast: a pill just above the bottom of the page (shape and
/// colours come from the theme's snackBarTheme) led by a tinted status
/// icon, so the outcome reads at a glance before the words do.
///
/// A newer toast replaces the current one rather than stacking.
void showAppToast(
  BuildContext context,
  String message, {
  AppToastTone tone = AppToastTone.info,
  IconData? icon,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
}) => showAppToastOn(
  ScaffoldMessenger.of(context),
  message,
  tone: tone,
  icon: icon,
  actionLabel: actionLabel,
  onAction: onAction,
  duration: duration,
);

/// [showAppToast] for call sites that captured the messenger before an
/// await, where the original context may be gone by the time the outcome is
/// known. Colours resolve inside the snackbar's own context, so no theme is
/// read through the stale one.
void showAppToastOn(
  ScaffoldMessengerState messenger,
  String message, {
  AppToastTone tone = AppToastTone.info,
  IconData? icon,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
}) {
  messenger.clearSnackBars();
  final hasAction = actionLabel != null && onAction != null;
  // The action can be tapped again during the exit animation.
  var fired = false;
  messenger.showSnackBar(
    SnackBar(
      duration: duration,
      // With no SnackBarAction, Flutter no longer keeps an actionable toast
      // up for screen-reader users; they need the time to reach the action.
      persist:
          hasAction &&
          MediaQuery.maybeAccessibleNavigationOf(messenger.context) == true,
      // The pill's shadow spills past the bar.
      clipBehavior: Clip.none,
      // The bar itself is invisible; the pill inside is the toast, drawn
      // from the theme's snackBarTheme colours and shape.
      behavior: SnackBarBehavior.fixed,
      backgroundColor: Colors.transparent,
      elevation: 0,
      padding: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(),
      content: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final bar = theme.snackBarTheme;
          final (fallback, color) = switch (tone) {
            AppToastTone.success => (Icons.check, Colors.green.shade600),
            AppToastTone.change => (Icons.edit_outlined, scheme.primary),
            AppToastTone.removal => (Icons.delete_outline, scheme.error),
            AppToastTone.error => (Icons.error_outline, scheme.error),
            AppToastTone.info => (Icons.info_outline, scheme.onSurfaceVariant),
          };
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Material(
              color: bar.backgroundColor ?? scheme.surfaceContainerHigh,
              shape:
                  bar.shape ??
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: bar.elevation ?? 6,
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  16,
                  hasAction ? 4 : 12,
                  hasAction ? 4 : 16,
                  hasAction ? 4 : 12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon ?? fallback, size: 16, color: color),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        message,
                        // The SnackBar default is light text for a dark
                        // bar; the pill is light unless the theme says
                        // otherwise.
                        style:
                            bar.contentTextStyle ??
                            TextStyle(color: scheme.onSurface),
                      ),
                    ),
                    if (actionLabel != null && onAction != null)
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor:
                              bar.actionTextColor ?? scheme.primary,
                        ),
                        onPressed: () {
                          if (fired) return;
                          fired = true;
                          messenger.hideCurrentSnackBar(
                            reason: SnackBarClosedReason.action,
                          );
                          onAction();
                        },
                        child: Text(actionLabel),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}
