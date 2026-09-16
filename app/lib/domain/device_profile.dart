/// Local-first companion app domain models (parent #6, slice #35).
///
/// Everything under `lib/domain/` is pure Dart with no plugins: models are
/// plain immutable data plus small stores held in memory. The app owns this
/// data on the user's device; nothing here performs networking, file
/// access, or persistence (that wiring is a later slice). Field bounds are
/// enforced at construction so malformed state cannot exist, mirroring the
/// contract gate in `protocol_contract.dart`.
library;

const int kMaxDeviceNameBytes = 64;
const int kMaxProfileNoteBytes = 160;
const int kMaxProfiles = 32;

int _utf8Length(String value) {
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

void _requireBounded(String value, int maximum, String field) {
  if (value.isEmpty) {
    throw ArgumentError('$field must not be empty');
  }
  if (_utf8Length(value) > maximum) {
    throw ArgumentError('$field exceeds $maximum UTF-8 bytes');
  }
}

/// One device the user has chosen to work with. `identity` is a stable
/// display label only — pairing credentials deliberately do NOT live in
/// this model (see threat model TM-08: credentials never appear in
/// exports), and discovery/transport are later slices.
class DeviceProfile {
  DeviceProfile({
    required this.identity,
    required this.displayName,
    this.note = '',
    this.addedAtUtc,
  }) {
    _requireBounded(identity, kMaxDeviceNameBytes, 'identity');
    _requireBounded(displayName, kMaxDeviceNameBytes, 'displayName');
    if (_utf8Length(note) > kMaxProfileNoteBytes) {
      throw ArgumentError('note exceeds $kMaxProfileNoteBytes UTF-8 bytes');
    }
  }

  /// Stable local identifier (for example a user-entered manual address or
  /// a future pairing id). Never a credential value.
  final String identity;
  final String displayName;
  final String note;

  /// Wall-clock add time when the caller knew it; null means "unknown",
  /// which keeps this model free of an implicit clock dependency in tests.
  final DateTime? addedAtUtc;

  Map<String, Object?> toMap() => {
    'identity': identity,
    'displayName': displayName,
    'note': note,
    'addedAtUtc': addedAtUtc?.toUtc().toIso8601String(),
  };

  static DeviceProfile fromMap(Map<Object?, Object?> map) {
    final identity = map['identity'];
    final displayName = map['displayName'];
    final note = map['note'] ?? '';
    final added = map['addedAtUtc'];
    if (identity is! String || displayName is! String || note is! String) {
      throw const FormatException('device profile has non-string fields');
    }
    DateTime? addedAt;
    if (added != null) {
      if (added is! String) {
        throw const FormatException('addedAtUtc must be a string or null');
      }
      addedAt = DateTime.tryParse(added);
      if (addedAt == null) {
        throw const FormatException('addedAtUtc is not ISO-8601');
      }
    }
    return DeviceProfile(
      identity: identity,
      displayName: displayName,
      note: note,
      addedAtUtc: addedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceProfile &&
      other.identity == identity &&
      other.displayName == displayName &&
      other.note == note &&
      other.addedAtUtc?.toUtc() == addedAtUtc?.toUtc();

  @override
  int get hashCode =>
      Object.hash(identity, displayName, note, addedAtUtc?.toUtc());
}

/// In-memory profile registry with bounded capacity and stable ordering.
class DeviceProfileStore {
  final List<DeviceProfile> _profiles = [];

  List<DeviceProfile> get profiles => List.unmodifiable(_profiles);

  DeviceProfile? byIdentity(String identity) {
    for (final profile in _profiles) {
      if (profile.identity == identity) {
        return profile;
      }
    }
    return null;
  }

  /// Adds or replaces by [DeviceProfile.identity]. Throws when the registry
  /// is full and the identity is new; replacing never changes capacity.
  void upsert(DeviceProfile profile) {
    final index = _profiles.indexWhere((p) => p.identity == profile.identity);
    if (index >= 0) {
      _profiles[index] = profile;
      return;
    }
    if (_profiles.length >= kMaxProfiles) {
      throw StateError('profile store is full ($kMaxProfiles)');
    }
    _profiles.add(profile);
  }

  bool remove(String identity) {
    final before = _profiles.length;
    _profiles.removeWhere((p) => p.identity == identity);
    return _profiles.length != before;
  }

  void replaceAll(Iterable<DeviceProfile> profiles) {
    _profiles
      ..clear()
      ..addAll(profiles);
  }
}
