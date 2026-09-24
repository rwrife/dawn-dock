/// Pure-Dart mirror of the firmware weekly recurrence resolver
/// (`firmware/components/alarm_core/recurrence_resolver.cpp`).
///
/// The firmware component is the normative occurrence-selection policy
/// (docs/alarm-semantics.md "Spring gap" / "Fall fold"): a nonexistent local
/// time shifts once to the earliest valid local instant on the same calendar
/// date, an ambiguous fold instant rings at its FIRST UTC occurrence only,
/// and malformed schedules/rule chains fail closed without partial results.
/// This port exists so the companion can preview "next alarm" (including the
/// `shiftedForGap` receipt label) locally, before any transport exists.
///
/// Parity rules for this file:
/// * The algorithm is a line-faithful port of the C++, including its
///   int64 overflow guards (Dart `int` on the VM is also a wrapping 64-bit
///   integer, so the same `canAdd`-style checks are required) and its
///   14-day bounded search window.
/// * Civil dates are bounded to the firmware's public `int32` year range so
///   both lanes reject the same instants (`outOfRange`) — deliberate parity,
///   not a Dart language limit.
/// * `app/test/recurrence_test.dart` asserts the identical instants,
///   offsets, local dates, and gap/fold flags as
///   `firmware/host/tests/recurrence_resolver_test.cpp`.
///
/// Host software evidence only: this is static analysis of the mirrored
/// policy. App/device output interoperability is unproven until both run on
/// hardware over an authenticated session.
library;

import 'alarm_draft.dart';

const int _secondsPerDay = 24 * 60 * 60;
const int _allIsoWeekdays = 0x7f;

/// Mirrors the firmware's 64-bit instant arithmetic limits.
const int kInt64Max = 0x7fffffffffffffff;
const int kInt64Min = ~0x7fffffffffffffff;

/// Deliberate parity bound: the firmware `CivilDate::year` is a 32-bit int,
/// so years outside this range fail closed as `outOfRange` on both lanes.
const int kCivilYearMin = -2147483648;
const int kCivilYearMax = 2147483647;

enum OccurrenceResolutionStatus {
  resolved,
  noOccurrence,
  invalidSchedule,
  invalidRules,
  outOfRange,
}

/// One UTC offset change: at `atUtcSeconds` the zone moves from
/// `offsetBeforeSeconds` to `offsetAfterSeconds` (UTC, epoch seconds).
class UtcOffsetTransition {
  const UtcOffsetTransition({
    required this.atUtcSeconds,
    required this.offsetBeforeSeconds,
    required this.offsetAfterSeconds,
  });

  final int atUtcSeconds;
  final int offsetBeforeSeconds;
  final int offsetAfterSeconds;

  @override
  bool operator ==(Object other) =>
      other is UtcOffsetTransition &&
      other.atUtcSeconds == atUtcSeconds &&
      other.offsetBeforeSeconds == offsetBeforeSeconds &&
      other.offsetAfterSeconds == offsetAfterSeconds;

  @override
  int get hashCode =>
      Object.hash(atUtcSeconds, offsetBeforeSeconds, offsetAfterSeconds);
}

/// Supplied UTC-offset rule chain for one IANA zone, mirroring the firmware
/// `TimezoneRules`. The caller supplies real rule data; nothing here reads
/// TZif files, the platform database, or the network.
class TimezoneRules {
  const TimezoneRules({
    required this.name,
    required this.version,
    required this.initialUtcOffsetSeconds,
    required this.transitions,
  });

  final String name;
  final String version;
  final int initialUtcOffsetSeconds;
  final List<UtcOffsetTransition> transitions;
}

/// One weekly alarm as the resolver sees it. Deliberately a raw data mirror
/// of the firmware POD: the constructor accepts ANY values (hour 24, empty
/// or out-of-range masks included) because fail-closed classification is
/// [resolveNextOccurrence]'s job, exactly as in C++. Use
/// [WeeklyOccurrenceSchedule.fromAlarm] for the validated [AlarmDraft] path.
class WeeklyOccurrenceSchedule {
  const WeeklyOccurrenceSchedule({
    required this.localHour,
    required this.localMinute,
    required this.isoWeekdayMask,
    required this.timezoneName,
    required this.timezoneRulesVersion,
  });

  /// Builds the resolver view from a bounded draft. The draft already
  /// enforces hour/minute/days/timezone bounds; the rule-set version is a
  /// separate provenance field supplied by whichever slice ships rule data.
  factory WeeklyOccurrenceSchedule.fromAlarm(
    AlarmDraft draft, {
    required String timezoneRulesVersion,
  }) {
    var mask = 0;
    for (final isoDay in draft.days) {
      mask |= 1 << (isoDay - 1); // ISO 1 = Monday = firmware bit 0.
    }
    return WeeklyOccurrenceSchedule(
      localHour: draft.localHour,
      localMinute: draft.localMinute,
      isoWeekdayMask: mask,
      timezoneName: draft.timezone,
      timezoneRulesVersion: timezoneRulesVersion,
    );
  }

  final int localHour;
  final int localMinute;

  /// Firmware bit layout: bit 0 = Monday .. bit 6 = Sunday; bits 7+ invalid.
  final int isoWeekdayMask;
  final String timezoneName;
  final String timezoneRulesVersion;
}

/// Calendar date in the alarm's zone (not necessarily UTC).
class CivilDate {
  const CivilDate({required this.year, required this.month, required this.day});

  final int year;
  final int month;
  final int day;

  @override
  bool operator ==(Object other) =>
      other is CivilDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      '$year-${month.toString().padLeft(2, '0')}'
      '-${day.toString().padLeft(2, '0')}';
}

/// Result of one resolution attempt. Instant fields are only meaningful when
/// [status] is [OccurrenceResolutionStatus.resolved].
class ResolvedOccurrence {
  const ResolvedOccurrence._({
    required this.status,
    this.scheduledUtcSeconds = 0,
    CivilDate? localDate,
    this.resolvedLocalHour = 0,
    this.resolvedLocalMinute = 0,
    this.utcOffsetSeconds = 0,
    this.shiftedForGap = false,
    this.ambiguousFold = false,
  }) : localDate = localDate ?? const CivilDate(year: 0, month: 0, day: 0);
  static ResolvedOccurrence _failure(OccurrenceResolutionStatus status) =>
      ResolvedOccurrence._(status: status);

  final OccurrenceResolutionStatus status;

  /// First scheduled instant strictly after the anchor (epoch seconds).
  final int scheduledUtcSeconds;

  /// Local calendar date whose weekday mask selected this occurrence. For a
  /// gap-shifted alarm this remains the requested date, never the shifted
  /// date — so a receipt can never label an absent day.
  final CivilDate localDate;
  final int resolvedLocalHour;
  final int resolvedLocalMinute;
  final int utcOffsetSeconds;

  /// The requested local time did not exist; scheduled at the earliest valid
  /// local instant after the gap (docs/alarm-semantics.md spring gap).
  final bool shiftedForGap;

  /// The local time occurred twice; this is the FIRST occurrence and no
  /// second ring will ever be produced for the same requested instant.
  final bool ambiguousFold;

  String get localTime =>
      '${resolvedLocalHour.toString().padLeft(2, '0')}:'
      '${resolvedLocalMinute.toString().padLeft(2, '0')}';

  @override
  String toString() => 'ResolvedOccurrence(${status.name}, $localTime)';
}

bool _validUtcOffset(int offset) =>
    offset >= -_secondsPerDay && offset <= _secondsPerDay;

bool _canAdd(int value, int offset) =>
    (offset >= 0 && value <= kInt64Max - offset) ||
    (offset < 0 && value >= kInt64Min - offset);

int _floorDiv(int numerator, int denominator) {
  final quotient = numerator ~/ denominator;
  final remainder = numerator.remainder(denominator);
  return remainder < 0 ? quotient - 1 : quotient;
}

int _weekdayIndexFromDays(int days) {
  // 1970-01-01 was Thursday (firmware weekday index 3).
  var index = (days + 3).remainder(7);
  if (index < 0) {
    index += 7;
  }
  return index;
}

CivilDate? _civilFromDays(int days) {
  days += 719468;
  final era = (days >= 0 ? days : days - 146096) ~/ 146097;
  final dayOfEra = days - era * 146097; // [0, 146096]
  final yearOfEra =
      (dayOfEra - dayOfEra ~/ 1460 + dayOfEra ~/ 36524 - dayOfEra ~/ 146096) ~/
      365;
  var year = yearOfEra + era * 400;
  final dayOfYear =
      dayOfEra - (365 * yearOfEra + yearOfEra ~/ 4 - yearOfEra ~/ 100);
  final monthPrime = (5 * dayOfYear + 2) ~/ 153;
  final day = dayOfYear - (153 * monthPrime + 2) ~/ 5 + 1;
  final month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9;
  if (month <= 2) {
    year += 1;
  }
  if (year < kCivilYearMin || year > kCivilYearMax) {
    return null;
  }
  return CivilDate(year: year, month: month, day: day);
}

int? _startOfDaySeconds(int day) {
  if (day > kInt64Max ~/ _secondsPerDay || day < kInt64Min ~/ _secondsPerDay) {
    return null;
  }
  return day * _secondsPerDay;
}

int _offsetAtUtc(TimezoneRules rules, int utcSeconds) {
  var offset = rules.initialUtcOffsetSeconds;
  for (final transition in rules.transitions) {
    if (utcSeconds < transition.atUtcSeconds) {
      break;
    }
    offset = transition.offsetAfterSeconds;
  }
  return offset;
}

bool _hasValidTransitionChain(TimezoneRules rules) {
  var activeOffset = rules.initialUtcOffsetSeconds;
  if (!_validUtcOffset(activeOffset)) {
    return false;
  }
  int? previousTransition;
  for (final transition in rules.transitions) {
    if ((previousTransition != null &&
            transition.atUtcSeconds <= previousTransition) ||
        transition.offsetBeforeSeconds != activeOffset ||
        !_validUtcOffset(transition.offsetBeforeSeconds) ||
        !_validUtcOffset(transition.offsetAfterSeconds) ||
        !_canAdd(transition.atUtcSeconds, transition.offsetBeforeSeconds) ||
        !_canAdd(transition.atUtcSeconds, transition.offsetAfterSeconds) ||
        transition.offsetBeforeSeconds == transition.offsetAfterSeconds) {
      return false;
    }
    previousTransition = transition.atUtcSeconds;
    activeOffset = transition.offsetAfterSeconds;
  }
  return true;
}

class _LocalMapping {
  const _LocalMapping({
    required this.utcSeconds,
    required this.resolvedLocalSeconds,
    required this.offsetSeconds,
    required this.shiftedForGap,
    required this.ambiguousFold,
  });

  final int utcSeconds;
  final int resolvedLocalSeconds;
  final int offsetSeconds;
  final bool shiftedForGap;
  final bool ambiguousFold;

  _LocalMapping withFold(bool fold) => _LocalMapping(
    utcSeconds: utcSeconds,
    resolvedLocalSeconds: resolvedLocalSeconds,
    offsetSeconds: offsetSeconds,
    shiftedForGap: shiftedForGap,
    ambiguousFold: fold,
  );
}

_LocalMapping? _mapLocal(TimezoneRules rules, int localSeconds) {
  // Spring gap: forward transitions only. Chain validation already proved
  // every at+offset is representable, so these sums cannot overflow.
  for (final transition in rules.transitions) {
    if (transition.offsetAfterSeconds <= transition.offsetBeforeSeconds) {
      continue;
    }
    final gapStart = transition.atUtcSeconds + transition.offsetBeforeSeconds;
    final gapEnd = transition.atUtcSeconds + transition.offsetAfterSeconds;
    if (localSeconds >= gapStart && localSeconds < gapEnd) {
      return _LocalMapping(
        utcSeconds: transition.atUtcSeconds,
        resolvedLocalSeconds: gapEnd,
        offsetSeconds: transition.offsetAfterSeconds,
        shiftedForGap: true,
        ambiguousFold: false,
      );
    }
  }

  final offsets = <int>[rules.initialUtcOffsetSeconds];
  for (final transition in rules.transitions) {
    if (!offsets.contains(transition.offsetAfterSeconds)) {
      offsets.add(transition.offsetAfterSeconds);
    }
  }

  _LocalMapping? earliest;
  var validMappingCount = 0;
  for (final offset in offsets) {
    final inverseOffset = -offset;
    if (!_canAdd(localSeconds, inverseOffset)) {
      continue;
    }
    final candidateUtc = localSeconds + inverseOffset;
    if (_offsetAtUtc(rules, candidateUtc) != offset) {
      continue;
    }
    validMappingCount += 1;
    if (earliest == null || candidateUtc < earliest.utcSeconds) {
      earliest = _LocalMapping(
        utcSeconds: candidateUtc,
        resolvedLocalSeconds: localSeconds,
        offsetSeconds: offset,
        shiftedForGap: false,
        ambiguousFold: false,
      );
    }
  }
  // Fall fold: every representation maps; v1 policy rings the earliest UTC
  // instant (the first pass through the repeated local time) only.
  return earliest?.withFold(validMappingCount > 1);
}

/// Returns the first scheduled occurrence strictly after [afterUtcSeconds],
/// mirroring `dawn::resolve_next_occurrence`. [rules] must be caller-supplied
/// real rule data (the firmware's pinned TZif adapter is the reference
/// producer); this function performs no platform timezone lookup.
ResolvedOccurrence resolveNextOccurrence({
  required WeeklyOccurrenceSchedule schedule,
  required TimezoneRules rules,
  required int afterUtcSeconds,
}) {
  if (schedule.localHour > 23 ||
      schedule.localMinute > 59 ||
      schedule.isoWeekdayMask == 0 ||
      (schedule.isoWeekdayMask & ~_allIsoWeekdays) != 0) {
    return ResolvedOccurrence._failure(
      OccurrenceResolutionStatus.invalidSchedule,
    );
  }
  if (schedule.timezoneName.isEmpty ||
      schedule.timezoneRulesVersion.isEmpty ||
      rules.name.isEmpty ||
      rules.version.isEmpty ||
      schedule.timezoneName != rules.name ||
      schedule.timezoneRulesVersion != rules.version ||
      !_hasValidTransitionChain(rules)) {
    return ResolvedOccurrence._failure(OccurrenceResolutionStatus.invalidRules);
  }
  if (afterUtcSeconds == kInt64Max) {
    return ResolvedOccurrence._failure(OccurrenceResolutionStatus.outOfRange);
  }
  final anchorOffset = _offsetAtUtc(rules, afterUtcSeconds);
  if ((anchorOffset > 0 && afterUtcSeconds > kInt64Max - anchorOffset) ||
      (anchorOffset < 0 && afterUtcSeconds < kInt64Min - anchorOffset)) {
    return ResolvedOccurrence._failure(OccurrenceResolutionStatus.outOfRange);
  }
  final anchorLocalSeconds = afterUtcSeconds + anchorOffset;
  final anchorDay = _floorDiv(anchorLocalSeconds, _secondsPerDay);

  for (var dayDelta = 0; dayDelta <= 14; dayDelta += 1) {
    final candidateDay = anchorDay + dayDelta;
    final weekday = _weekdayIndexFromDays(candidateDay);
    if ((schedule.isoWeekdayMask & (1 << weekday)) == 0) {
      continue;
    }
    final dayStart = _startOfDaySeconds(candidateDay);
    final secondsInRequestedDay =
        schedule.localHour * 60 * 60 + schedule.localMinute * 60;
    if (dayStart == null || dayStart > kInt64Max - secondsInRequestedDay) {
      return ResolvedOccurrence._failure(OccurrenceResolutionStatus.outOfRange);
    }
    final localSeconds = dayStart + secondsInRequestedDay;
    final mapping = _mapLocal(rules, localSeconds);
    if (mapping == null || mapping.utcSeconds <= afterUtcSeconds) {
      continue;
    }
    final resolvedDay = _floorDiv(mapping.resolvedLocalSeconds, _secondsPerDay);
    if (mapping.shiftedForGap && resolvedDay != candidateDay) {
      // A shift that lands on a different calendar date is not the v1
      // single-gap policy for this date; keep searching (the firmware skips
      // the date entirely — see the Apia fixture).
      continue;
    }
    final secondsInDay =
        mapping.resolvedLocalSeconds - resolvedDay * _secondsPerDay;
    final localDate = _civilFromDays(candidateDay);
    if (localDate == null) {
      return ResolvedOccurrence._failure(OccurrenceResolutionStatus.outOfRange);
    }
    return ResolvedOccurrence._(
      status: OccurrenceResolutionStatus.resolved,
      scheduledUtcSeconds: mapping.utcSeconds,
      localDate: localDate,
      resolvedLocalHour: secondsInDay ~/ (60 * 60),
      resolvedLocalMinute: secondsInDay ~/ 60 % 60,
      utcOffsetSeconds: mapping.offsetSeconds,
      shiftedForGap: mapping.shiftedForGap,
      ambiguousFold: mapping.ambiguousFold,
    );
  }
  return ResolvedOccurrence._failure(OccurrenceResolutionStatus.noOccurrence);
}
