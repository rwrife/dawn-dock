/// Demo-scoped screen mounting [BackupFlowPanel] over a real file-backed
/// [LocalBackupStore].
///
/// This page exists to close the integration gap left by issue #55: the
/// panel was host-tested against an in-memory store double and mounted
/// nowhere. Here the panel runs against a real `LocalBackupStore` writing
/// `companion-backup-v1.json` into a caller-supplied directory (the demo
/// navigation passes the OS temporary directory), so host widget tests can
/// assert actual file creation, discovery, and deletion.
///
/// Honest scope of what this is NOT:
///
/// * The live stores (profiles, drafts, schedule mirror) are fresh in-memory
///   session state; edits made elsewhere in the app are not shared here.
/// * The backup directory is demo-scoped temporary storage — not platform
///   private storage, not encrypted, and not guaranteed to survive OS cleanup
///   or app reinstall. No `path_provider`, file picker, or share sheet is
///   involved; the directory is injected by the caller.
/// * Nothing here talks to real hardware, a transport, or pairing.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../domain/alarm_draft.dart';
import '../domain/backup_coordinator.dart';
import '../domain/backup_flow_controller.dart';
import '../domain/device_profile.dart';
import '../domain/local_backup_store.dart';
import '../domain/schedule_store.dart';
import 'backup_flow_panel.dart';

/// Backup/restore demo page over a real [LocalBackupStore].
class BackupDemoPage extends StatefulWidget {
  const BackupDemoPage({super.key, required this.backupDirectory});

  /// Directory the backup file is written to. Injectable so host tests can
  /// point at a disposable directory; the demo navigation passes
  /// [Directory.systemTemp].
  final Directory backupDirectory;

  @override
  State<BackupDemoPage> createState() => _BackupDemoPageState();
}

class _BackupDemoPageState extends State<BackupDemoPage> {
  late final DeviceProfileStore _profiles;
  late final DraftSet _drafts;
  late final DeviceScheduleStore _schedule;
  late final LocalBackupStore _backupStore;
  late final BackupFlowController _controller;

  @override
  void initState() {
    super.initState();
    _profiles = DeviceProfileStore();
    _drafts = DraftSet();
    _schedule = DeviceScheduleStore();
    _backupStore = LocalBackupStore(directory: widget.backupDirectory);
    _controller = BackupFlowController(
      coordinator: BackupCoordinator(
        backupStore: _backupStore,
        profileStore: _profiles,
        draftSet: _drafts,
        scheduleStore: _schedule,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup demo • Temporary storage')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Backup demo • Temporary directory',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'The backup file lives in this app\'s temporary '
                    'directory: not private, not encrypted, and not '
                    'guaranteed to survive cleanup or reinstall.',
                    key: ValueKey('storage-notice'),
                  ),
                  const Text(
                    'Profile, draft, and schedule state on this page is '
                    'in-memory demo state for this widget session only.',
                    key: ValueKey('state-notice'),
                  ),
                  const Text(
                    'Nothing here connects to a real clock.',
                    key: ValueKey('no-hardware-notice'),
                  ),
                  const SizedBox(height: 12),
                  BackupFlowPanel(controller: _controller),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
