/// Versioned JSON local backups for the companion's own state
/// (device profiles, alarm drafts, schedule mirror).
///
/// Design rules that the host tests pin down:
/// * `format` + `version` gate every restore; unknown versions fail closed.
/// * Every field is validated against model bounds BEFORE any state is
///   replaced — a rejected restore can never leave partial state.
/// * Unknown keys are rejected, and any key name that smells like a
///   credential is rejected even before key-shape checks, so a crafted
///   backup can neither smuggle fields nor round-trip secrets (threat
///   model TM-08: credentials never appear in exports).
/// * Bounded size: the raw text is capped before parsing.
library;

import 'dart:convert';

import 'alarm_draft.dart';
import 'device_profile.dart';
import 'schedule_store.dart';

const String kBackupFormat = 'dawndock-companion-backup';
const int kBackupVersion = 1;
const int kMaxBackupTextBytes = 1024 * 1024;

/// Substrings that must never appear (case-insensitively) in any backup key
/// path. The app never writes these, so any occurrence is either a
/// hand-crafted file or a future bug leaking secrets into user-visible
/// state — both are restore-blocking.
const List<String> kReservedKeyTokens = [
  'credential',
  'token',
  'secret',
  'password',
  'passphrase',
  'apikey',
  'api_key',
  'privatekey',
  'private_key',
  'pairingcode',
];

class BackupException implements Exception {
  BackupException(this.message, {this.path});
  final String message;
  final String? path;

  @override
  String toString() =>
      'BackupException: $message${path == null ? '' : ' (at $path)'}';
}

void _requireReservedKeyScan(Object? node, String path) {
  if (node is Map) {
    for (final entry in node.entries) {
      final key = '${entry.key}'.toLowerCase();
      for (final token in kReservedKeyTokens) {
        if (key.contains(token)) {
          throw BackupException(
            'reserved credential-like key excluded from backups',
            path: '$path/${entry.key}',
          );
        }
      }
      _requireReservedKeyScan(entry.value, '$path/${entry.key}');
    }
  } else if (node is List) {
    for (var i = 0; i < node.length; i++) {
      _requireReservedKeyScan(node[i], '$path/$i');
    }
  }
}

bool _keySetMatches(Map<Object?, Object?> map, Set<String> required) {
  final keys = map.keys.map((k) => '$k').toSet();
  return keys.length == required.length && keys.containsAll(required);
}

/// Fully validated, immutable backup contents. Construct via [parse]; call
/// [applyTo] only when the caller is ready to replace live state.
class CompanionBackup {
  CompanionBackup._({
    required this.exportedAtUtc,
    required this.deviceProfiles,
    required this.drafts,
    required this.knownRevision,
    required this.committedAlarms,
    required this.lastReceipt,
  });

  final DateTime exportedAtUtc;
  final List<DeviceProfile> deviceProfiles;
  final List<AlarmDraft> drafts;
  final int knownRevision;
  final List<AlarmDraft> committedAlarms;
  final SyncReceipt? lastReceipt;

  /// Serializes the current app state into canonical backup text.
  static String encode({
    required DateTime exportedAtUtc,
    required List<DeviceProfile> deviceProfiles,
    required List<AlarmDraft> drafts,
    required int knownRevision,
    required List<AlarmDraft> committedAlarms,
    SyncReceipt? lastReceipt,
  }) {
    if (deviceProfiles.length > kMaxProfiles) {
      throw ArgumentError('too many device profiles to export');
    }
    if (drafts.length > kMaxDrafts || committedAlarms.length > kMaxDrafts) {
      throw ArgumentError('too many drafts to export');
    }
    final document = <String, Object?>{
      'format': kBackupFormat,
      'version': kBackupVersion,
      'exportedAtUtc': exportedAtUtc.toUtc().toIso8601String(),
      'deviceProfiles': deviceProfiles.map((p) => p.toMap()).toList(),
      'drafts': drafts.map((d) => d.toMap()).toList(),
      'scheduleMirror': {
        'knownRevision': knownRevision,
        'committedAlarms': committedAlarms.map((d) => d.toMap()).toList(),
        'lastReceipt': lastReceipt?.toMap(),
      },
    };
    // Fail closed on our own output: never export a document that would
    // not survive its own reserved-key scan.
    _requireReservedKeyScan(document, '');
    return const JsonEncoder.withIndent('  ').convert(document);
  }

  /// Parses and fully validates backup text. Throws [BackupException] on any
  /// violation and produces no side effects.
  static CompanionBackup parse(String text) {
    if (utf8.encode(text).length > kMaxBackupTextBytes) {
      throw BackupException('backup exceeds $kMaxBackupTextBytes bytes');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw BackupException('not valid JSON: ${error.message}');
    }
    _requireReservedKeyScan(decoded, '');
    if (decoded is! Map) {
      throw BackupException('backup root must be an object');
    }
    final root = decoded.cast<Object?, Object?>();
    if (!_keySetMatches(root, {
      'format',
      'version',
      'exportedAtUtc',
      'deviceProfiles',
      'drafts',
      'scheduleMirror',
    })) {
      throw BackupException('backup root keys are not exact');
    }
    if (root['format'] != kBackupFormat) {
      throw BackupException(
        'unknown backup format '
        '${root.containsKey('format') ? root['format'] : '(missing)'}',
      );
    }
    final version = root['version'];
    if (version is! int || version != kBackupVersion) {
      throw BackupException(
        'unsupported backup version $version '
        '(this build understands $kBackupVersion)',
      );
    }
    final exportedAt = DateTime.tryParse(
      root['exportedAtUtc'] as String? ?? '',
    );
    if (exportedAt == null) {
      throw BackupException(
        'exportedAtUtc is missing or not ISO-8601',
        path: '/exportedAtUtc',
      );
    }

    final profilesRaw = _requireList(
      root['deviceProfiles'],
      '/deviceProfiles',
      kMaxProfiles,
    );
    final draftsRaw = _requireList(root['drafts'], '/drafts', kMaxDrafts);
    final mirrorRaw = root['scheduleMirror'];
    if (mirrorRaw is! Map) {
      throw BackupException(
        'scheduleMirror must be an object',
        path: '/scheduleMirror',
      );
    }
    final mirror = mirrorRaw.cast<Object?, Object?>();
    if (!_keySetMatches(mirror, {
      'knownRevision',
      'committedAlarms',
      'lastReceipt',
    })) {
      throw BackupException(
        'scheduleMirror keys are not exact',
        path: '/scheduleMirror',
      );
    }
    final knownRevision = mirror['knownRevision'];
    if (knownRevision is! int || knownRevision < 0) {
      throw BackupException(
        'knownRevision must be a non-negative integer',
        path: '/scheduleMirror/knownRevision',
      );
    }
    final committedRaw = _requireList(
      mirror['committedAlarms'],
      '/scheduleMirror/committedAlarms',
      kMaxDrafts,
    );

    try {
      final profiles = profilesRaw
          .map(
            (e) => DeviceProfile.fromMap((e as Map).cast<Object?, Object?>()),
          )
          .toList(growable: false);
      final profileIds = profiles.map((p) => p.identity).toSet();
      if (profileIds.length != profiles.length) {
        throw BackupException(
          'duplicate device profile identity',
          path: '/deviceProfiles',
        );
      }
      final drafts = _parseDrafts(draftsRaw, '/drafts');
      final committed = _parseDrafts(
        committedRaw,
        '/scheduleMirror/committedAlarms',
      );
      SyncReceipt? receipt;
      if (mirror['lastReceipt'] != null) {
        receipt = SyncReceipt.fromMap(
          (mirror['lastReceipt']! as Map).cast<Object?, Object?>(),
        );
        if (receipt.appliedRevision != knownRevision) {
          throw BackupException(
            'lastReceipt revision does not match knownRevision',
            path: '/scheduleMirror/lastReceipt',
          );
        }
        if (receipt.alarmCount != committed.length) {
          throw BackupException(
            'lastReceipt alarmCount does not match committedAlarms',
            path: '/scheduleMirror/lastReceipt',
          );
        }
      }
      return CompanionBackup._(
        exportedAtUtc: exportedAt.toUtc(),
        deviceProfiles: profiles,
        drafts: _sortedById(drafts),
        knownRevision: knownRevision,
        committedAlarms: _sortedById(committed),
        lastReceipt: receipt,
      );
    } on BackupException {
      rethrow;
    } on FormatException catch (error) {
      throw BackupException('model validation failed: $error');
    } on ArgumentError catch (error) {
      throw BackupException('model validation failed: $error');
    } on TypeError catch (error) {
      throw BackupException('model validation failed: $error');
    }
  }

  /// Replaces live state in the provided stores. Only called after a
  /// successful [parse], so every entry is already model-validated; this
  /// method itself cannot throw for content reasons.
  void applyTo({
    required DeviceProfileStore profileStore,
    required DraftSet draftSet,
    required DeviceScheduleStore scheduleStore,
  }) {
    profileStore.replaceAll(deviceProfiles);
    draftSet.replaceAll(drafts);
    scheduleStore.replaceAll(
      revision: knownRevision,
      alarms: committedAlarms,
      receipt: lastReceipt,
    );
  }
}

/// Parsed collections are canonicalized to id order so a restore result
/// never depends on how a hand-edited file happened to order its arrays.
List<AlarmDraft> _sortedById(List<AlarmDraft> drafts) =>
    [...drafts]..sort((a, b) => a.id.compareTo(b.id));

List<Object?> _requireList(Object? value, String path, int maximum) {
  if (value is! List) {
    throw BackupException('must be an array', path: path);
  }
  if (value.length > maximum) {
    throw BackupException('array exceeds $maximum entries', path: path);
  }
  return value;
}

List<AlarmDraft> _parseDrafts(List<Object?> raw, String path) {
  final drafts = <AlarmDraft>[];
  final ids = <String>{};
  for (var i = 0; i < raw.length; i++) {
    final entry = raw[i];
    if (entry is! Map) {
      throw BackupException('draft must be an object', path: '$path/$i');
    }
    final draft = AlarmDraft.fromMap(entry.cast<Object?, Object?>());
    if (!ids.add(draft.id)) {
      throw BackupException('duplicate draft id ${draft.id}', path: '$path/$i');
    }
    drafts.add(draft);
  }
  return drafts;
}
