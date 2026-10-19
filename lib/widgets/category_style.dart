import 'package:flutter/material.dart';

import '../platform/usage_source.dart';
import '../theme/drift_theme.dart';

/// The name the Usage tab shows for an [AppCategories] value.
String categoryLabel(String category) => switch (category) {
  AppCategories.game => 'Games',
  AppCategories.audio => 'Music and audio',
  AppCategories.video => 'Video',
  AppCategories.image => 'Photos',
  AppCategories.social => 'Social',
  AppCategories.news => 'News',
  AppCategories.maps => 'Maps',
  AppCategories.productivity => 'Productivity',
  AppCategories.accessibility => 'Accessibility',
  _ => 'Other',
};

const _dark = {
  AppCategories.social: Color(0xFF9B8CFF),
  AppCategories.video: Color(0xFFF28CB8),
  AppCategories.game: Color(0xFFFF9F5A),
  AppCategories.productivity: Color(0xFF4CC9C0),
  AppCategories.audio: Color(0xFF74A7FF),
  AppCategories.news: Color(0xFFD9B98C),
  AppCategories.image: Color(0xFF7FD4F0),
  AppCategories.maps: Color(0xFFB5D46A),
  AppCategories.accessibility: Color(0xFFE0A0E0),
};

const _light = {
  AppCategories.social: Color(0xFF6A55D8),
  AppCategories.video: Color(0xFFC94C86),
  AppCategories.game: Color(0xFFC8662A),
  AppCategories.productivity: Color(0xFF13998C),
  AppCategories.audio: Color(0xFF3B6FD8),
  AppCategories.news: Color(0xFFA07A40),
  AppCategories.image: Color(0xFF2A8FB5),
  AppCategories.maps: Color(0xFF6E8F22),
  AppCategories.accessibility: Color(0xFFA0509F),
};

/// A category's colour on the Usage ring and dots: fixed hues, darker on
/// the light themes. None is the on-track, off-track or guessed colour,
/// because Usage says nothing about the plan. Other is the secondary text
/// colour.
Color categoryColor(BuildContext context, String category) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return (dark ? _dark : _light)[category] ?? context.drift.textSecondary;
}
