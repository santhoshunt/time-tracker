/// The source of "now" for everything that depends on the time of day.
///
/// Domain code and screens read the time through a [Clock] instead of
/// calling `DateTime.now()`, so tests can pin the day and the minute and
/// get the same answer on every run.
abstract class Clock {
  const Clock();

  /// The current local time.
  DateTime now();
}

/// The real wall clock, used by the app.
class SystemClock extends Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// A clock that returns whatever [value] holds, for tests. [value] is
/// mutable so a test can move time forward between two calls.
class FixedClock extends Clock {
  FixedClock(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}
