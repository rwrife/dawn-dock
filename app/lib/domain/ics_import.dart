/// Dependency-free importer for a bounded RFC 5545 (`text/calendar`) subset.
///
/// Turns calendar text into reviewable [AlarmDraft] suggestions plus
/// machine-readable [IcsImportNotice]s. The importer is pure: no UI, no
/// filesystem, no transport, no IANA zone database, and no wall-clock
/// conversion — zone identifiers and local wall times are preserved exactly
/// as written (nonexistent-local / fold policy is the firmware's job, see
/// `tzif_rules`).
///
/// Field retention is bounded *structurally*: the result types have no field
/// that could carry `DESCRIPTION`, `ATTENDEE`, `LOCATION`, or any other
/// calendar content beyond `UID`, `SUMMARY`, `DTSTART`, and a minimal
/// `RRULE` subset, so such content cannot leak even if the parser reads it.
library;

import 'dart:convert';

import 'alarm_draft.dart';
import 'protocol_contract.dart'
    show
        kMaxAlarmLabelBytes,
        kMaxSourceEventIdBytes,
        kMaxStoredAlarms,
        kMaxTimezoneBytes;

/// A machine-readable judgment the importer made on the user's behalf.
/// [code] is a stable, localizable-key-style identifier; [eventNumber] is the
/// 1-based `VEVENT` position in file order (null for whole-input notices).
class IcsImportNotice {
  const IcsImportNotice({required this.code, this.eventNumber, this.detail});

  final String code;
  final int? eventNumber;
  final String? detail;

  Map<String, Object?> toMap() => {
    'code': code,
    'eventNumber': eventNumber,
    'detail': detail,
  };

  @override
  bool operator ==(Object other) =>
      other is IcsImportNotice &&
      other.code == code &&
      other.eventNumber == eventNumber &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(code, eventNumber, detail);

  @override
  String toString() =>
      'IcsImportNotice($code${eventNumber == null ? '' : ' #$eventNumber'}'
      '${detail == null ? '' : ', $detail'})';
}

/// Base class for whole-import rejections. A failure listed here aborts the
/// entire import — partial suggestions are never produced for an input that
/// fails a fail-closed gate.
class IcsImportException implements Exception {
  const IcsImportException(this.message);

  final String message;

  @override
  String toString() => 'IcsImportException: $message';
}

/// The input exceeds [kIcsImportMaxInputBytes].
class IcsImportInputTooLargeException extends IcsImportException {
  const IcsImportInputTooLargeException(super.message);
}

/// The input declares more than [kIcsImportMaxEvents] `VEVENT` blocks.
class IcsImportTooManyEventsException extends IcsImportException {
  const IcsImportTooManyEventsException(super.message);
}

/// The input has no `BEGIN:VCALENDAR` line and is therefore not a calendar.
class IcsImportNotCalendarException extends IcsImportException {
  const IcsImportNotCalendarException(super.message);
}

/// UTF-8 input ceiling for one import (fail-closed gate 1).
const int kIcsImportMaxInputBytes = 1024 * 1024;

/// Maximum number of `VEVENT` blocks per import (fail-closed gate 2).
const int kIcsImportMaxEvents = 256;

// ---------------------------------------------------------------------------
// Stable notice codes (localization keys — never show the raw code to a
// user without a translation, and never re-purpose a code's meaning).
// ---------------------------------------------------------------------------

/// `DTSTART` had no `TZID` and no `Z`: the time is floating; it was stored
/// under the app default zone and the user must confirm the intended zone.
const String kIcsNoticeFloatingLocalTime = 'floating-local-time';

/// The event carries UTC wall time (trailing `Z` or a UTC-designator `TZID`)
/// but alarms are stored as wall time in a named zone; the user must confirm
/// the zone the wall time should live in.
const String kIcsNoticeUtcWallTime = 'utc-wall-time';

/// An all-day (`VALUE=DATE`) event has no time; midnight was used.
const String kIcsNoticeAllDayDefaultTime = 'all-day-default-time';

/// An RRULE part (e.g. `INTERVAL=2`) cannot be represented by a fixed
/// weekday mask; the event was dropped.
const String kIcsNoticeIntervalNotRepresentable = 'interval-not-representable';

/// The recurrence carried an end condition (`COUNT`/`UNTIL`) that a weekday
/// mask cannot express; the end was dropped from the suggestion.
const String kIcsNoticeRecurrenceEndDropped = 'recurrence-end-dropped';

/// A `WEEKLY` rule with no `BYDAY`/`COUNT`/`UNTIL` was expanded to recur on
/// the event's own weekday forever.
const String kIcsNoticeSingleOccurrenceWeekly = 'single-occurrence-weekly';

/// `SUMMARY` was absent or empty after sanitization; a generic label was
/// used.
const String kIcsNoticeLabelDefaulted = 'label-defaulted';

/// `SUMMARY` exceeded the 48-byte label bound and was truncated on a
/// code-point boundary.
const String kIcsNoticeLabelTruncated = 'label-truncated';

/// The event had no `UID`; it was dropped (ids and provenance require one).
const String kIcsNoticeMissingUid = 'missing-uid';

/// A previous event already used this `UID`; this event's draft id was
/// collision-suffixed so the suggestion stays reviewable.
const String kIcsNoticeDuplicateUid = 'duplicate-uid';

/// The `UID` exceeds `kMaxSourceEventIdBytes`; the event was dropped.
const String kIcsNoticeOversizedUid = 'oversized-uid';

/// `DTSTART` is absent, malformed, has an impossible date/time, or carries a
/// `TZID` that cannot fit the timezone field; the event was dropped.
const String kIcsNoticeInvalidDtstart = 'invalid-dtstart';

/// The `VEVENT` block was structurally malformed (nested, unterminated, or a
/// repeated core property); it was dropped.
const String kIcsNoticeMalformedEvent = 'malformed-event';

/// The import produced more than `kMaxStoredAlarms` suggestions; later
/// events in file order were not suggested.
const String kIcsNoticeCapacityTruncated = 'capacity-truncated';

/// The `RRULE` uses a frequency or part (`MONTHLY`, `YEARLY`, `BYSETPOS`,
/// unknown parts, values a weekday mask cannot model) that is unsupported;
/// the event was dropped.
const String kIcsNoticeUnsupportedRecurrence = 'unsupported-recurrence';

/// The `DTSTART` had a `TZID` parameter whose value was empty; the event was
/// dropped (no defensible zone can be guessed).
const String kIcsNoticeMissingTzid = 'missing-tzid';

/// The `TZID` was a UTC designator; see [kIcsNoticeUtcWallTime] — both are
/// emitted so a UI can distinguish "no zone given" from "zone given was
/// UTC".
const String kIcsNoticeUtcTimezoneId = 'utc-timezone-id';

/// Stable lowercase identifiers for every notice this importer can emit.
const List<String> kIcsImportNoticeCodes = [
  kIcsNoticeFloatingLocalTime,
  kIcsNoticeUtcWallTime,
  kIcsNoticeAllDayDefaultTime,
  kIcsNoticeIntervalNotRepresentable,
  kIcsNoticeRecurrenceEndDropped,
  kIcsNoticeSingleOccurrenceWeekly,
  kIcsNoticeLabelDefaulted,
  kIcsNoticeLabelTruncated,
  kIcsNoticeMissingUid,
  kIcsNoticeDuplicateUid,
  kIcsNoticeOversizedUid,
  kIcsNoticeInvalidDtstart,
  kIcsNoticeMalformedEvent,
  kIcsNoticeCapacityTruncated,
  kIcsNoticeUnsupportedRecurrence,
  kIcsNoticeMissingTzid,
  kIcsNoticeUtcTimezoneId,
];

/// Outcome of one import: suggestions in file order plus every notice, in
/// file order as well.
class IcsImportResult {
  const IcsImportResult({required this.suggestions, required this.notices});

  final List<AlarmDraft> suggestions;
  final List<IcsImportNotice> notices;
}

/// Default timezone offered for floating local times. There is no zone
/// database in the pinned dependency set, so the importer cannot resolve or
/// validate IANA identifiers beyond length bounds — the user confirms or
/// edits every floating suggestion before it can become an alarm.
const String kIcsImportDefaultTimezone = 'Etc/UTC';

/// Default `AlarmDraft` fields for suggestions (the calendar does not carry
/// snooze/volume/sound; these are safe in-bounds defaults the user reviews).
const bool kIcsDraftEnabled = true;
const int kIcsDraftSnoozeMinutes = 5;
const int kIcsDraftVolume = 80;
const String kIcsDraftSound = 'chime';
const String kIcsDefaultLabel = 'Calendar alarm';

/// Parses [text] as an RFC 5545 subset and returns reviewable suggestions.
///
/// Throws [IcsImportInputTooLargeException], [IcsImportTooManyEventsException]
/// or [IcsImportNotCalendarException] (in that precedence order) for inputs
/// rejected wholesale. Every per-event judgment is surfaced as a notice.
IcsImportResult importIcsSuggestions(String text) {
  if (_utf8Length(text) > kIcsImportMaxInputBytes) {
    throw const IcsImportInputTooLargeException(
      'input exceeds the 1 MiB import ceiling',
    );
  }
  final lines = _unfold(text);
  final isCalendar = lines.any((line) {
    final prop = _propertyOf(line);
    return prop != null &&
        prop.name == 'BEGIN' &&
        prop.rawValue.toUpperCase() == 'VCALENDAR';
  });
  if (!isCalendar) {
    throw const IcsImportNotCalendarException('missing BEGIN:VCALENDAR');
  }

  final blocks = _splitVEvents(lines);
  if (blocks.length > kIcsImportMaxEvents) {
    throw IcsImportTooManyEventsException(
      'more than $kIcsImportMaxEvents VEVENT blocks (${blocks.length})',
    );
  }

  final notices = <IcsImportNotice>[];
  final suggestions = <AlarmDraft>[];
  final usedIds = <String>{};
  final firstDroppedByCapacity = <int>[];

  for (var i = 0; i < blocks.length; i++) {
    final eventNumber = i + 1;
    final draft = _draftForEvent(
      blocks[i],
      eventNumber: eventNumber,
      notices: notices,
      usedIds: usedIds,
    );
    if (draft == null) {
      continue;
    }
    if (suggestions.length >= kMaxStoredAlarms) {
      firstDroppedByCapacity.add(eventNumber);
      continue;
    }
    suggestions.add(draft);
  }

  if (firstDroppedByCapacity.isNotEmpty) {
    notices.add(
      IcsImportNotice(
        code: kIcsNoticeCapacityTruncated,
        eventNumber: firstDroppedByCapacity.first,
        detail:
            '${firstDroppedByCapacity.length} event(s) beyond the '
            '$kMaxStoredAlarms-suggestion cap were not suggested',
      ),
    );
  }

  return IcsImportResult(
    suggestions: List.unmodifiable(suggestions),
    notices: List.unmodifiable(notices),
  );
}

// ---------------------------------------------------------------------------
// Line unfolding (RFC 5545 §3.1)
// ---------------------------------------------------------------------------

/// Splits on LF/CRLF/CR boundaries and joins continuation lines (a follow-on
/// line starting with SPACE or TAB) per RFC. A line that ends the file with
/// its fold is treated as content, not dropped.
List<String> _unfold(String text) {
  final raw = text.split(RegExp(r'\r\n|\n|\r'));
  final out = <String>[];
  for (final line in raw) {
    if (line.isEmpty) {
      continue;
    }
    final first = line.codeUnitAt(0);
    if (out.isNotEmpty && (first == 0x20 || first == 0x09)) {
      out[out.length - 1] = out[out.length - 1] + line.substring(1);
    } else {
      out.add(line);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Property parsing
// ---------------------------------------------------------------------------

class _Property {
  const _Property({
    required this.name,
    required this.params,
    required this.rawValue,
  });

  final String name;
  final Map<String, String> params;
  final String rawValue;

  String textValue() => _unescapeText(rawValue);
}

_Property? _propertyOf(String line) {
  final colon = line.indexOf(':');
  if (colon < 0) {
    return null;
  }
  final nameSection = line.substring(0, colon);
  final parts = nameSection.split(';');
  final name = parts.first.toUpperCase();
  if (name.isEmpty) {
    return null;
  }
  final params = <String, String>{};
  for (final param in parts.skip(1)) {
    final eq = param.indexOf('=');
    if (eq > 0) {
      params[param.substring(0, eq).toUpperCase()] = param
          .substring(eq + 1)
          .replaceAll('"', '');
    }
  }
  return _Property(
    name: name,
    params: params,
    rawValue: line.substring(colon + 1),
  );
}

/// RFC 5545 §3.3.11 text-value escapes. A stray backslash is dropped rather
/// than kept, so sanitized labels never contain raw escape syntax.
String _unescapeText(String value) {
  if (!value.contains(r'\')) {
    return value;
  }
  final out = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    if (value[i] != r'\') {
      out.write(value[i]);
      continue;
    }
    if (i + 1 >= value.length) {
      continue; // trailing lone escape — drop it
    }
    final next = value[i + 1];
    switch (next) {
      case 'n':
      case 'N':
        out.write('\n');
      case ',':
      case ';':
      case r'\':
      case ':':
        out.write(next);
      default:
        out.write(next);
    }
    i++;
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// VEVENT extraction
// ---------------------------------------------------------------------------

class _EventBlock {
  bool malformed = false;
  String? uid;
  String? summary;
  _Property? dtstart;
  final List<String> rruleValues = [];
}

/// Splits the flat property stream into per-`VEVENT` accumulators. Content
/// outside any event (VTIMEZONE etc.) is discarded structurally: only the
/// four retained properties are ever stored, and only inside a block.
List<_EventBlock> _splitVEvents(List<String> lines) {
  final blocks = <_EventBlock>[];
  _EventBlock? open;
  for (final line in lines) {
    final prop = _propertyOf(line);
    if (prop == null) {
      if (open != null) {
        open.malformed = true; // unparseable line inside an event
      }
      continue;
    }
    if (prop.name == 'BEGIN' && prop.rawValue.toUpperCase() == 'VEVENT') {
      if (open != null) {
        open.malformed = true; // nested BEGIN:VEVENT
        continue;
      }
      open = _EventBlock();
      blocks.add(open);
      continue;
    }
    if (prop.name == 'END' && prop.rawValue.toUpperCase() == 'VEVENT') {
      open = null;
      continue;
    }
    if (open == null) {
      continue; // outside any VEVENT — never retained
    }
    switch (prop.name) {
      case 'UID':
        if (open.uid != null) {
          open.malformed = true;
        } else {
          open.uid = prop.rawValue;
        }
      case 'SUMMARY':
        if (open.summary != null) {
          open.malformed = true;
        } else {
          open.summary = prop.textValue();
        }
      case 'DTSTART':
        if (open.dtstart != null) {
          open.malformed = true;
        } else {
          open.dtstart = prop;
        }
      case 'RRULE':
        if (open.rruleValues.isNotEmpty) {
          open.malformed = true; // RFC 5545: at most one RRULE per VEVENT
        } else {
          open.rruleValues.add(prop.rawValue);
        }
      default:
        break; // DESCRIPTION / ATTENDEE / LOCATION / ... : no field, no leak
    }
  }
  // A BEGIN:VEVENT without a matching END is malformed content.
  if (open != null) {
    open.malformed = true;
  }
  return blocks;
}

// ---------------------------------------------------------------------------
// Per-event suggestion building
// ---------------------------------------------------------------------------

AlarmDraft? _draftForEvent(
  _EventBlock block, {
  required int eventNumber,
  required List<IcsImportNotice> notices,
  required Set<String> usedIds,
}) {
  void note(String code, {String? detail}) => notices.add(
    IcsImportNotice(code: code, eventNumber: eventNumber, detail: detail),
  );

  if (block.malformed) {
    note(kIcsNoticeMalformedEvent);
    return null;
  }
  if (block.rruleValues.length > 1) {
    // RFC 5545 forbids multiple RRULEs per component; the extras are dropped
    // and the judgment is surfaced as a recurrence-end judgment.
    note(kIcsNoticeRecurrenceEndDropped, detail: 'multiple RRULE properties');
  }

  final uid = block.uid;
  if (uid == null || uid.isEmpty) {
    note(kIcsNoticeMissingUid);
    return null;
  }
  if (_utf8Length(uid) > kMaxSourceEventIdBytes) {
    note(kIcsNoticeOversizedUid);
    return null;
  }

  // --- DTSTART -------------------------------------------------------------
  final start = _parseDtstart(block.dtstart, onNotice: note);
  if (start == null) {
    return null;
  }

  // --- RRULE -> weekday mask ----------------------------------------------
  final days = _daysFromRrule(
    rruleValue: block.rruleValues.isEmpty ? null : block.rruleValues.first,
    eventWeekdayIso: start.weekdayIso,
    onNotice: note,
  );
  if (days == null) {
    return null;
  }

  // --- label ----------------------------------------------------------------
  var label = _sanitizeLabel(block.summary ?? '');
  if (label.isEmpty) {
    label = kIcsDefaultLabel;
    note(kIcsNoticeLabelDefaulted);
  }
  final capped = _truncateUtf8(label, kMaxAlarmLabelBytes);
  if (capped != label) {
    note(kIcsNoticeLabelTruncated);
  }
  label = capped;

  // --- deterministic id with collision suffixing ---------------------------
  var id = 'ics-${_fnv1a64Hex(uid)}';
  var suffix = 1;
  while (usedIds.contains(id)) {
    suffix++;
    id = 'ics-${_fnv1a64Hex(uid)}-$suffix';
  }
  usedIds.add(id);
  if (suffix > 1) {
    note(kIcsNoticeDuplicateUid);
  }

  try {
    return AlarmDraft(
      id: id,
      label: label,
      enabled: kIcsDraftEnabled,
      localHour: start.hour,
      localMinute: start.minute,
      days: days,
      timezone: start.timezone,
      snoozeMinutes: kIcsDraftSnoozeMinutes,
      volume: kIcsDraftVolume,
      sound: kIcsDraftSound,
      source: DraftSource.ics,
      provenance: ImportProvenance(sourceEventId: uid, originLabel: 'ics'),
    );
  } on ArgumentError {
    // Defensive: AlarmDraft re-validates every field; any bound the
    // importer failed to pre-check lands here and the event is dropped so
    // no suggestion can carry out-of-contract content.
    note(kIcsNoticeInvalidDtstart, detail: 'draft bounds violated');
    return null;
  }
}

class _StartInfo {
  const _StartInfo({
    required this.hour,
    required this.minute,
    required this.timezone,
    required this.weekdayIso,
  });

  final int hour;
  final int minute;
  final String timezone;

  /// ISO weekday (1 = Monday .. 7 = Sunday) of the literal calendar date.
  final int weekdayIso;
}

final RegExp _dateTimePattern = RegExp(
  r'^(\d{4})(\d{2})(\d{2})[Tt](\d{2})(\d{2})(\d{2})([Zz])?$',
);
final RegExp _datePattern = RegExp(r'^(\d{4})(\d{2})(\d{2})$');

const Set<String> _utcTzids = {'UTC', 'Z', 'GMT', 'ETC/UTC'};

_StartInfo? _parseDtstart(
  _Property? prop, {
  required void Function(String code, {String? detail}) onNotice,
}) {
  if (prop == null) {
    onNotice(kIcsNoticeInvalidDtstart, detail: 'no DTSTART');
    return null;
  }
  final value = prop.rawValue.trim();
  final tzidParam = prop.params['TZID'];

  var hour = 0;
  var minute = 0;
  int year;
  int month;
  int day;
  String timezone;

  final isDateValue = (prop.params['VALUE']?.toUpperCase() == 'DATE');

  final dtMatch = _dateTimePattern.firstMatch(value);
  final dMatch = _datePattern.firstMatch(value);
  if (dtMatch != null && !isDateValue) {
    year = int.parse(dtMatch.group(1)!);
    month = int.parse(dtMatch.group(2)!);
    day = int.parse(dtMatch.group(3)!);
    hour = int.parse(dtMatch.group(4)!);
    minute = int.parse(dtMatch.group(5)!);
    final seconds = int.parse(dtMatch.group(6)!);
    final zulu = dtMatch.group(7) != null;
    if (seconds > 59) {
      onNotice(kIcsNoticeInvalidDtstart, detail: 'seconds outside a minute');
      return null;
    }
    if (zulu || (tzidParam != null && _isUtcDesignator(tzidParam))) {
      // Wall time in UTC cannot be re-homed without a zone database; keep
      // the literal wall time and make the user confirm the zone.
      timezone = kIcsImportDefaultTimezone;
      onNotice(kIcsNoticeUtcWallTime);
      if (tzidParam != null && !zulu) {
        onNotice(kIcsNoticeUtcTimezoneId);
      }
    } else if (tzidParam == null) {
      timezone = kIcsImportDefaultTimezone;
      onNotice(kIcsNoticeFloatingLocalTime);
    } else {
      final tid = tzidParam.trim();
      if (tid.isEmpty) {
        onNotice(kIcsNoticeMissingTzid);
        return null;
      }
      if (_utf8Length(tid) < 3 || _utf8Length(tid) > kMaxTimezoneBytes) {
        // Outside the timezone field's bounds — no defensible clamp.
        onNotice(
          kIcsNoticeInvalidDtstart,
          detail: 'TZID violates field bounds',
        );
        return null;
      }
      timezone = tid;
    }
  } else if (dMatch != null && (isDateValue || dtMatch == null)) {
    year = int.parse(dMatch.group(1)!);
    month = int.parse(dMatch.group(2)!);
    day = int.parse(dMatch.group(3)!);
    timezone = kIcsImportDefaultTimezone;
    onNotice(kIcsNoticeAllDayDefaultTime);
  } else {
    onNotice(kIcsNoticeInvalidDtstart, detail: 'unrecognized DTSTART value');
    return null;
  }

  if (!_validGregorian(year, month, day) || hour > 23 || minute > 59) {
    onNotice(kIcsNoticeInvalidDtstart, detail: 'impossible calendar value');
    return null;
  }

  return _StartInfo(
    hour: hour,
    minute: minute,
    timezone: timezone,
    weekdayIso: _isoWeekday(year, month, day),
  );
}

bool _isUtcDesignator(String tzid) =>
    _utcTzids.contains(tzid.trim().toUpperCase());

/// Proleptic-Gregorian calendar validation without a DateTime import so
/// leap years and month lengths are checked exactly.
bool _validGregorian(int year, int month, int day) {
  if (year < 1 || month < 1 || month > 12 || day < 1) {
    return false;
  }
  const monthLengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  var length = monthLengths[month - 1];
  if (month == 2 && ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0)) {
    length = 29;
  }
  return day <= length;
}

/// ISO weekday (1 = Monday .. 7 = Sunday) from a proleptic Gregorian date
/// via Tomohiko Sakamoto's day-of-week algorithm.
int _isoWeekday(int year, int month, int day) {
  const offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
  var y = year;
  if (month < 3) {
    y -= 1;
  }
  final dow =
      (y + y ~/ 4 - y ~/ 100 + y ~/ 400 + offsets[month - 1] + day) %
      7; // 0=Sunday
  return dow == 0 ? 7 : dow;
}

// ---------------------------------------------------------------------------
// RRULE subset
// ---------------------------------------------------------------------------

const Map<String, int> _bydayToIso = {
  'MO': 1,
  'TU': 2,
  'WE': 3,
  'TH': 4,
  'FR': 5,
  'SA': 6,
  'SU': 7,
};

/// Maps the supported RRULE subset onto an ISO weekday mask. Returns null
/// when the event must be dropped (notice already recorded via [onNotice]).
Set<int>? _daysFromRrule({
  required String? rruleValue,
  required int eventWeekdayIso,
  required void Function(String code, {String? detail}) onNotice,
}) {
  if (rruleValue == null) {
    // A single occurrence is expanded to recur weekly on its own weekday —
    // the closest weekday-mask representation, always surfaced.
    onNotice(kIcsNoticeSingleOccurrenceWeekly);
    return {eventWeekdayIso};
  }

  String? freq;
  var interval = 1;
  var countSeen = false;
  var untilSeen = false;
  final byDays = <int>{};
  var bydaySeen = false;

  for (final part in rruleValue.split(';')) {
    if (part.isEmpty) {
      continue;
    }
    final eq = part.indexOf('=');
    if (eq <= 0) {
      onNotice(
        kIcsNoticeUnsupportedRecurrence,
        detail: 'RRULE part without a value',
      );
      return null;
    }
    final key = part.substring(0, eq).toUpperCase();
    final value = part.substring(eq + 1);
    switch (key) {
      case 'FREQ':
        freq = value.toUpperCase();
      case 'INTERVAL':
        final parsed = int.tryParse(value);
        if (parsed == null || parsed < 1) {
          onNotice(
            kIcsNoticeUnsupportedRecurrence,
            detail: 'INTERVAL is not a positive integer',
          );
          return null;
        }
        interval = parsed;
      case 'COUNT':
        if (int.tryParse(value) == null) {
          onNotice(
            kIcsNoticeUnsupportedRecurrence,
            detail: 'COUNT is not an integer',
          );
          return null;
        }
        countSeen = true;
      case 'UNTIL':
        if (!_isIcsInstant(value)) {
          onNotice(
            kIcsNoticeUnsupportedRecurrence,
            detail: 'UNTIL is not an ICS instant',
          );
          return null;
        }
        untilSeen = true;
      case 'BYDAY':
        bydaySeen = true;
        for (final token in value.split(',')) {
          final iso = _bydayToIso[_stripBydayOrdinal(token).toUpperCase()];
          if (iso == null) {
            onNotice(
              kIcsNoticeUnsupportedRecurrence,
              detail: 'unknown BYDAY day "$token"',
            );
            return null;
          }
          byDays.add(iso);
        }
      default:
        onNotice(
          kIcsNoticeUnsupportedRecurrence,
          detail: 'unsupported RRULE part "$key"',
        );
        return null;
    }
  }

  if (freq == null) {
    onNotice(kIcsNoticeUnsupportedRecurrence, detail: 'RRULE has no FREQ');
    return null;
  }
  if (interval != 1) {
    onNotice(kIcsNoticeIntervalNotRepresentable, detail: 'INTERVAL=$interval');
    return null;
  }
  if (countSeen || untilSeen) {
    onNotice(kIcsNoticeRecurrenceEndDropped);
  }

  switch (freq) {
    case 'DAILY':
      return {1, 2, 3, 4, 5, 6, 7};
    case 'WEEKLY':
      if (bydaySeen) {
        return byDays;
      }
      onNotice(kIcsNoticeSingleOccurrenceWeekly);
      return {eventWeekdayIso};
    default:
      onNotice(
        kIcsNoticeUnsupportedRecurrence,
        detail:
            'FREQ=$freq needs calendar arithmetic a weekday mask cannot '
            'represent',
      );
      return null;
  }
}

/// Strips an optional RFC 5545 ordinal prefix (`+3TU`, `-1MO`) from a BYDAY
/// token — nth-weekday semantics are already rejected via BYSETPOS-style
/// unsupportedness, but plain ordinals also occur without BYSETPOS.
String _stripBydayOrdinal(String token) {
  final trimmed = token.trim();
  final match = RegExp(r'^[+-]?\d*([A-Za-z]{2})$').firstMatch(trimmed);
  return match == null ? trimmed : match.group(1)!;
}

bool _isIcsInstant(String value) =>
    _dateTimePattern.hasMatch(value.trim()) ||
    _datePattern.hasMatch(value.trim());

// ---------------------------------------------------------------------------
// Label sanitization / truncation
// ---------------------------------------------------------------------------

/// Single-line, control-character-free rendering of a text value: all
/// whitespace runs (including unescaped newlines from `\n`) collapse to a
/// single SPACE and are trimmed.
String _sanitizeLabel(String value) {
  final stripped = value.replaceAll(
    RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
    '',
  );
  return stripped.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Truncates to at most [maxBytes] UTF-8 bytes without splitting a code
/// point (never leaves half of a surrogate pair).
String _truncateUtf8(String value, int maxBytes) {
  if (_utf8Length(value) <= maxBytes) {
    return value;
  }
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in value.runes) {
    final size = _runeUtf8Bytes(rune);
    if (bytes + size > maxBytes) {
      break;
    }
    buffer.writeCharCode(rune);
    bytes += size;
  }
  return buffer.toString();
}

int _runeUtf8Bytes(int rune) {
  if (rune < 0x80) {
    return 1;
  } else if (rune < 0x800) {
    return 2;
  } else if (rune < 0x10000) {
    return 3;
  }
  return 4;
}

int _utf8Length(String value) => utf8.encode(value).length;

// ---------------------------------------------------------------------------
// Deterministic id derivation
// ---------------------------------------------------------------------------

/// FNV-1a 64-bit hash in 16-char lowercase hex. Non-cryptographic by design:
/// ids must be stable and collision-visible, not adversarially unpredictable
/// (collision suffixing plus user review cover the rest).
String _fnv1a64Hex(String value) {
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final unit in utf8.encode(value)) {
    hash ^= unit;
    hash = _mul64(hash, prime);
  }
  // Dart ints are signed 64-bit: the unsigned bit pattern may exceed
  // int.maxSigned, so reformat through BigInt to carry the full 64 bits.
  return BigInt.from(hash).toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// 64-bit wrapping multiply without relying on 64-bit word semantics.
int _mul64(int a, int b) {
  const mask = 0xFFFFFFFF;
  final aLo = a & mask;
  final aHi = (a >> 32) & mask;
  final bLo = b & mask;
  final bHi = (b >> 32) & mask;
  var result = aLo * bLo;
  result += ((aHi * bLo) + (aLo * bHi)) << 32;
  return result & 0xFFFFFFFFFFFFFFFF;
}
