/// Host-testable local file persistence for companion backups.
///
/// Keeps persistence policy in the pure Dart domain layer by taking an explicit
/// directory path from the caller. Platform directory selection (for example
/// via path_provider) is outside this slice.
library;

import 'dart:convert';
import 'dart:io';

import 'alarm_draft.dart';
import 'backup.dart';
import 'device_profile.dart';
import 'schedule_store.dart';

const String kDefaultBackupFileName = 'companion-backup-v1.json';

class LocalBackupStore {
  LocalBackupStore({
    required this._directory,
    String fileName = kDefaultBackupFileName,
  }) : _fileName = _validatedFileName(fileName);

  final Directory _directory;
  final String _fileName;

  static String _validatedFileName(String fileName) {
    if (fileName.isEmpty ||
        fileName == '.' ||
        fileName == '..' ||
        fileName.contains('/') ||
        fileName.contains(r'\')) {
      throw ArgumentError('fileName must be a non-empty basename');
    }
    return fileName;
  }

  File get file =>
      File('${_directory.path}${Platform.pathSeparator}$_fileName');

  Future<void> saveText(String backupText) async {
    final bytes = utf8.encode(backupText).length;
    if (bytes > kMaxBackupTextBytes) {
      throw BackupException('backup exceeds $kMaxBackupTextBytes bytes');
    }

    await _directory.create(recursive: true);

    final target = file;
    final tmp = File(
      '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );

    await tmp.writeAsString(backupText, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException catch (error) {
      try {
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (_) {
        // Best-effort cleanup only.
      }
      throw BackupException('atomic backup write failed: ${error.message}');
    }
  }

  Future<void> save({
    required DateTime exportedAtUtc,
    required List<DeviceProfile> deviceProfiles,
    required List<AlarmDraft> drafts,
    required int knownRevision,
    required List<AlarmDraft> committedAlarms,
    SyncReceipt? lastReceipt,
  }) {
    final text = CompanionBackup.encode(
      exportedAtUtc: exportedAtUtc,
      deviceProfiles: deviceProfiles,
      drafts: drafts,
      knownRevision: knownRevision,
      committedAlarms: committedAlarms,
      lastReceipt: lastReceipt,
    );
    return saveText(text);
  }

  Future<String?> loadText() async {
    final target = file;
    if (!await target.exists()) {
      return null;
    }

    String text;
    try {
      text = await target.readAsString();
    } on FormatException {
      throw BackupException('backup file is not valid UTF-8 text');
    }
    final bytes = utf8.encode(text).length;
    if (bytes > kMaxBackupTextBytes) {
      throw BackupException('backup exceeds $kMaxBackupTextBytes bytes');
    }
    return text;
  }

  Future<CompanionBackup?> load() async {
    final text = await loadText();
    if (text == null) {
      return null;
    }
    return CompanionBackup.parse(text);
  }

  Future<void> erase() async {
    final target = file;
    if (!await target.exists()) {
      return;
    }
    await target.delete();
  }
}
