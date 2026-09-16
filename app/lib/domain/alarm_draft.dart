/// Editable alarm drafts and their bounded import provenance.
library;

import 'protocol_contract.dart'
    show
        kMaxAlarmLabelBytes,
        kMaxSourceEventIdBytes,
        kMaxSoundBytes,
        kMaxStoredAlarms,
        kMaxTimezoneBytes;

final RegExp _draftIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

enum DraftSource { manual, ics }

/// Where a draft came from. Kept deliberately minimal: per the protocol,
/// imported alarms transfer only the fields an accepted alarm needs, so a
/// provenance record may reference an originating event id but must never
/// carry description, attendee, or location content (enforced structurally:
/// there is simply no field for them).
class ImportProvenance {
  const ImportProvenance({
    required this.sourceEventId,
    required this.originLabel,
  });

  final String sourceEventId;

  /// Human-localizable label for the import channel ('ics' file pick,
  /// future providers). Never free text from the imported file itself.
  final String originLabel;

  static const int maxOriginLabelBytes = 32;

  Map<String, Object?> toMap() => {
    'sourceEventId': sourceEventId,
    'originLabel': originLabel,
  };

  static ImportProvenance fromMap(Map<Object?, Object?> map) {
    final eventId = map['sourceEventId'];
    final label = map['originLabel'];
    if (eventId is! String ||
        eventId.isEmpty ||
        _utf8(eventId) > kMaxSourceEventIdBytes) {
      throw const FormatException('invalid sourceEventId');
    }
    if (label is! String ||
        label.isEmpty ||
        _utf8(label) > maxOriginLabelBytes) {
      throw const FormatException('invalid originLabel');
    }
    return ImportProvenance(sourceEventId: eventId, originLabel: label);
  }

  @override
  bool operator ==(Object other) =>
      other is ImportProvenance &&
      other.sourceEventId == sourceEventId &&
      other.originLabel == originLabel;

  @override
  int get hashCode => Object.hash(sourceEventId, originLabel);
}

/// One unsaved alarm the user (or an import suggestion) is editing. All
/// bounds match the wire contract so a draft that validates here serializes
/// identically for schedule.preview / schedule.apply once transport lands.
class AlarmDraft {
  AlarmDraft({
    required this.id,
    required this.label,
    required this.enabled,
    required this.localHour,
    required this.localMinute,
    required this.days,
    required this.timezone,
    required this.snoozeMinutes,
    required this.volume,
    required this.sound,
    required this.source,
    this.provenance,
  }) {
    _validate();
  }

  final String id;
  final String label;
  final bool enabled;
  final int localHour;
  final int localMinute;

  /// ISO weekday numbers, 1 = Monday .. 7 = Sunday (wire days are 0..6
  /// Monday..Sunday; conversion lives in [toWireDays]).
  final Set<int> days;

  final String timezone;
  final int snoozeMinutes;
  final int volume;
  final String sound;
  final DraftSource source;

  /// Only legal when [source] is [DraftSource.ics]; conversely an ics-sourced
  /// draft must carry it, so provenance and source cannot disagree.
  final ImportProvenance? provenance;

  String get localTime =>
      '${localHour.toString().padLeft(2, '0')}:${localMinute.toString().padLeft(2, '0')}';

  List<int> toWireDays() =>
      days.map((iso) => iso - 1).toList(growable: false)..sort();

  Map<String, Object?> toWireAlarm() => {
    'id': id,
    'label': label,
    'enabled': enabled,
    'localTime': localTime,
    'days': toWireDays(),
    'timezone': timezone,
    'snoozeMinutes': snoozeMinutes,
    'volume': volume,
    'sound': sound,
    'source': switch (source) {
      DraftSource.manual => 'manual',
      DraftSource.ics => 'ics',
    },
    'sourceEventId': provenance?.sourceEventId,
  };

  AlarmDraft copyWith({
    String? label,
    bool? enabled,
    int? localHour,
    int? localMinute,
    Set<int>? days,
    String? timezone,
    int? snoozeMinutes,
    int? volume,
    String? sound,
  }) => AlarmDraft(
    id: id,
    label: label ?? this.label,
    enabled: enabled ?? this.enabled,
    localHour: localHour ?? this.localHour,
    localMinute: localMinute ?? this.localMinute,
    days: days ?? this.days,
    timezone: timezone ?? this.timezone,
    snoozeMinutes: snoozeMinutes ?? this.snoozeMinutes,
    volume: volume ?? this.volume,
    sound: sound ?? this.sound,
    source: source,
    provenance: provenance,
  );

  void _validate() {
    if (!_draftIdPattern.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'not a valid alarm id');
    }
    if (label.isEmpty || _utf8(label) > kMaxAlarmLabelBytes) {
      throw ArgumentError.value(label, 'label', 'label bound violated');
    }
    if (localHour < 0 ||
        localHour > 23 ||
        localMinute < 0 ||
        localMinute > 59) {
      throw ArgumentError.value(
        '$localHour:$localMinute',
        'localTime',
        'outside a day',
      );
    }
    if (days.isEmpty || days.length > 7 || days.any((d) => d < 1 || d > 7)) {
      throw ArgumentError.value(days, 'days', 'weekday mask invalid');
    }
    if (_utf8(timezone) < 3 || _utf8(timezone) > kMaxTimezoneBytes) {
      throw ArgumentError.value(
        timezone,
        'timezone',
        'timezone bound violated',
      );
    }
    if (snoozeMinutes < 1 || snoozeMinutes > 30) {
      throw ArgumentError.value(
        snoozeMinutes,
        'snoozeMinutes',
        'outside 1..30',
      );
    }
    if (volume < 0 || volume > 100) {
      throw ArgumentError.value(volume, 'volume', 'outside 0..100');
    }
    if (sound.isEmpty || _utf8(sound) > kMaxSoundBytes) {
      throw ArgumentError.value(sound, 'sound', 'sound bound violated');
    }
    if (source == DraftSource.ics && provenance == null) {
      throw ArgumentError('ics drafts must carry provenance');
    }
    if (source == DraftSource.manual && provenance != null) {
      throw ArgumentError('manual drafts must not carry provenance');
    }
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'label': label,
    'enabled': enabled,
    'localHour': localHour,
    'localMinute': localMinute,
    'days': days.toList()..sort(),
    'timezone': timezone,
    'snoozeMinutes': snoozeMinutes,
    'volume': volume,
    'sound': sound,
    'source': switch (source) {
      DraftSource.manual => 'manual',
      DraftSource.ics => 'ics',
    },
    'provenance': provenance?.toMap(),
  };

  static AlarmDraft fromMap(Map<Object?, Object?> map) {
    Object? need(String key) {
      if (!map.containsKey(key)) {
        throw FormatException('draft missing $key');
      }
      return map[key];
    }

    final sourceName = need('source');
    final provenanceMap = map['provenance'];
    final provenance = provenanceMap == null
        ? null
        : ImportProvenance.fromMap(
            (provenanceMap as Map).cast<Object?, Object?>(),
          );
    final days = need('days');
    if (days is! List) {
      throw const FormatException('days must be a list');
    }
    return AlarmDraft(
      id: need('id') as String,
      label: need('label') as String,
      enabled: need('enabled') as bool,
      localHour: need('localHour') as int,
      localMinute: need('localMinute') as int,
      days: days.cast<int>().toSet(),
      timezone: need('timezone') as String,
      snoozeMinutes: need('snoozeMinutes') as int,
      volume: need('volume') as int,
      sound: need('sound') as String,
      source: switch (sourceName) {
        'manual' => DraftSource.manual,
        'ics' => DraftSource.ics,
        _ => throw const FormatException('unknown draft source'),
      },
      provenance: provenance,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AlarmDraft &&
      other.id == id &&
      other.label == label &&
      other.enabled == enabled &&
      other.localHour == localHour &&
      other.localMinute == localMinute &&
      other.days.length == days.length &&
      other.days.containsAll(days) &&
      other.timezone == timezone &&
      other.snoozeMinutes == snoozeMinutes &&
      other.volume == volume &&
      other.sound == sound &&
      other.source == source &&
      other.provenance == provenance;

  @override
  int get hashCode => Object.hash(
    id,
    label,
    enabled,
    localTime,
    Object.hashAllUnordered(days),
    timezone,
    snoozeMinutes,
    volume,
    sound,
    source,
    provenance,
  );
}

int _utf8(String value) {
  var bytes = 0;
  for (final unit in value.runes) {
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit < 0x10000) {
      bytes += 3;
    } else {
      bytes += 4;
    }
  }
  return bytes;
}

/// Drafts must never be able to describe a schedule the device would
/// refuse: capacity is the same bound the wire contract enforces.
const int kMaxDrafts = kMaxStoredAlarms;

/// In-memory working set the user edits before any preview/apply. Draft
/// edits are local and side-effect free — nothing here talks to a device.
class DraftSet {
  final Map<String, AlarmDraft> _drafts = {};

  List<AlarmDraft> get drafts {
    final sorted = _drafts.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(sorted);
  }

  int get length => _drafts.length;

  AlarmDraft? byId(String id) => _drafts[id];

  void put(AlarmDraft draft) {
    if (!_drafts.containsKey(draft.id) && _drafts.length >= kMaxDrafts) {
      throw StateError('draft set is full ($kMaxDrafts)');
    }
    _drafts[draft.id] = draft;
  }

  bool remove(String id) => _drafts.remove(id) != null;

  void clear() => _drafts.clear();

  void replaceAll(Iterable<AlarmDraft> drafts) {
    _drafts
      ..clear()
      ..addEntries(drafts.map((d) => MapEntry(d.id, d)));
  }
}
