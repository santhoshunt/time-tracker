import '../platform/usage_source.dart';
import 'models.dart';

/// Categories whose apps are guessed off track when no rule or override
/// says otherwise. These are the ones that most often pull attention away
/// from a plan; everything else gets the benefit of the doubt.
const guessOffCategories = {
  AppCategories.game,
  AppCategories.video,
  AppCategories.social,
  AppCategories.news,
};

/// The verdict for an app nobody has ruled on yet, from its Android
/// category alone. The result is a guess, shown amber until answered.
Verdict guessFor(String category) =>
    guessOffCategories.contains(category) ? Verdict.guessedOff : Verdict.guessedOn;
