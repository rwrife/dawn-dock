/// Presentation state controller for companion backup and restore workflows.
///
/// Wraps [BackupCoordinator] with deterministic state transitions suitable for
/// accessible screen code. Rules pinned by host tests:
///
/// * State transitions are strictly serialized: an in-flight operation causes
///   subsequent calls to return false immediately without starting an overlapping
///   coordinator action.
/// * Failures preserve the previous operational context where possible and expose
///   whether the problem was an unreadable/corrupt backup, an operational error,
///   or a stale schedule revision.
/// * A stale restore request transitions the controller to [BackupStaleConfirmationRequired]
///   without mutating any live store. Confirmation must be invoked via an explicit
///   [confirmStaleRestore] call, which retries the exact pending backup with `allowStale: true`.
/// * Erase is idempotent and results in [BackupAbsent] state on success.
/// * In-memory restore can also be driven via [restoreParsedBackup].
library;

import 'backup.dart';
import 'backup_coordinator.dart';

/// The kind of operation currently in progress or recently completed.
enum BackupOperation { export, inspect, restore, erase }

/// Sealed hierarchy of presentation states for backup flows.
sealed class BackupFlowState {
  const BackupFlowState();
}

/// Initial state before any backup operation has run.
final class BackupInitial extends BackupFlowState {
  const BackupInitial();

  @override
  String toString() => 'BackupInitial()';
}

/// An operation is currently executing.
final class BackupBusy extends BackupFlowState {
  const BackupBusy({required this.operation, this.previousSummary});

  final BackupOperation operation;
  final BackupSummary? previousSummary;

  @override
  String toString() =>
      'BackupBusy(operation: ${operation.name}, previousSummary: $previousSummary)';
}

/// Inspection or restore established that no saved backup file exists.
final class BackupAbsent extends BackupFlowState {
  const BackupAbsent({required this.operation});

  final BackupOperation operation;

  @override
  String toString() => 'BackupAbsent(operation: ${operation.name})';
}

/// An operation completed successfully with an available backup summary.
final class BackupSuccess extends BackupFlowState {
  const BackupSuccess({
    required this.operation,
    required this.summary,
    required this.completedAtUtc,
  });

  final BackupOperation operation;
  final BackupSummary summary;
  final DateTime completedAtUtc;

  @override
  String toString() =>
      'BackupSuccess(operation: ${operation.name}, summary: $summary, completedAtUtc: $completedAtUtc)';
}

/// Restore was refused because the backup revision is older than the current
/// schedule store revision. Live stores were left untouched.
final class BackupStaleConfirmationRequired extends BackupFlowState {
  const BackupStaleConfirmationRequired({
    required this.pendingBackup,
    required this.summary,
    required this.currentRevision,
    required this.backupRevision,
  });

  final CompanionBackup pendingBackup;
  final BackupSummary summary;
  final int currentRevision;
  final int backupRevision;

  @override
  String toString() =>
      'BackupStaleConfirmationRequired(backupRev: $backupRevision, currentRev: $currentRevision)';
}

/// An operation failed with an error.
final class BackupFailure extends BackupFlowState {
  const BackupFailure({
    required this.operation,
    required this.message,
    this.path,
    this.previousSummary,
  });

  final BackupOperation operation;
  final String message;
  final String? path;
  final BackupSummary? previousSummary;

  @override
  String toString() =>
      'BackupFailure(operation: ${operation.name}, message: $message, path: $path)';
}

/// Presentation controller coordinating UI-level backup actions against [BackupCoordinator].
class BackupFlowController {
  BackupFlowController({required this.coordinator, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final BackupCoordinator coordinator;
  final DateTime Function() _clock;

  BackupFlowState _state = const BackupInitial();
  bool _isBusy = false;

  BackupFlowState get state => _state;
  bool get isBusy => _isBusy;

  BackupSummary? get lastSummary {
    return switch (_state) {
      BackupSuccess(:final summary) => summary,
      BackupBusy(:final previousSummary) => previousSummary,
      BackupFailure(:final previousSummary) => previousSummary,
      BackupStaleConfirmationRequired(:final summary) => summary,
      _ => null,
    };
  }

  /// Exports current live stores to a local backup file and transitions to [BackupSuccess].
  /// Returns true if the export was initiated, or false if an operation was already in-flight.
  Future<bool> export() async {
    if (_isBusy) return false;
    _isBusy = true;
    final prev = lastSummary;
    _state = BackupBusy(
      operation: BackupOperation.export,
      previousSummary: prev,
    );

    try {
      final summary = await coordinator.export();
      _state = BackupSuccess(
        operation: BackupOperation.export,
        summary: summary,
        completedAtUtc: _clock().toUtc(),
      );
      return true;
    } on BackupException catch (e) {
      _state = BackupFailure(
        operation: BackupOperation.export,
        message: e.message,
        path: e.path,
        previousSummary: prev,
      );
      return true;
    } catch (e) {
      _state = BackupFailure(
        operation: BackupOperation.export,
        message: e.toString(),
        previousSummary: prev,
      );
      return true;
    } finally {
      _isBusy = false;
    }
  }

  /// Inspects the saved backup file without mutating any live stores.
  /// Transitions to [BackupSuccess] if found, [BackupAbsent] if missing, or [BackupFailure] if corrupt.
  Future<bool> inspect() async {
    if (_isBusy) return false;
    _isBusy = true;
    final prev = lastSummary;
    _state = BackupBusy(
      operation: BackupOperation.inspect,
      previousSummary: prev,
    );

    try {
      final summary = await coordinator.inspect();
      if (summary == null) {
        _state = const BackupAbsent(operation: BackupOperation.inspect);
      } else {
        _state = BackupSuccess(
          operation: BackupOperation.inspect,
          summary: summary,
          completedAtUtc: _clock().toUtc(),
        );
      }
      return true;
    } on BackupException catch (e) {
      _state = BackupFailure(
        operation: BackupOperation.inspect,
        message: e.message,
        path: e.path,
        previousSummary: prev,
      );
      return true;
    } catch (e) {
      _state = BackupFailure(
        operation: BackupOperation.inspect,
        message: e.toString(),
        previousSummary: prev,
      );
      return true;
    } finally {
      _isBusy = false;
    }
  }

  /// Restores from the saved backup file into live stores.
  /// If the backup is older than current schedule revision, prompts with
  /// [BackupStaleConfirmationRequired] without mutating any stores.
  Future<bool> restore() async {
    if (_isBusy) return false;
    _isBusy = true;
    final prev = lastSummary;
    _state = BackupBusy(
      operation: BackupOperation.restore,
      previousSummary: prev,
    );

    try {
      final backup = await coordinator.backupStore.load();
      if (backup == null) {
        _state = const BackupAbsent(operation: BackupOperation.restore);
        return true;
      }

      final currentRevision = coordinator.scheduleStore.knownRevision;
      if (backup.knownRevision < currentRevision) {
        _state = BackupStaleConfirmationRequired(
          pendingBackup: backup,
          summary: BackupSummary.fromBackup(backup),
          currentRevision: currentRevision,
          backupRevision: backup.knownRevision,
        );
        return true;
      }

      final summary = coordinator.restoreBackup(backup, allowStale: false);
      _state = BackupSuccess(
        operation: BackupOperation.restore,
        summary: summary,
        completedAtUtc: _clock().toUtc(),
      );
      return true;
    } on BackupException catch (e) {
      _state = BackupFailure(
        operation: BackupOperation.restore,
        message: e.message,
        path: e.path,
        previousSummary: prev,
      );
      return true;
    } catch (e) {
      _state = BackupFailure(
        operation: BackupOperation.restore,
        message: e.toString(),
        previousSummary: prev,
      );
      return true;
    } finally {
      _isBusy = false;
    }
  }

  /// Confirms and applies a previously refused stale restore.
  /// Throws [StateError] if state is not [BackupStaleConfirmationRequired].
  Future<bool> confirmStaleRestore() async {
    if (_isBusy) return false;
    final current = _state;
    if (current is! BackupStaleConfirmationRequired) {
      throw StateError(
        'cannot confirm stale restore: current state is ${current.runtimeType}',
      );
    }

    _isBusy = true;
    final prev = current.summary;
    _state = BackupBusy(
      operation: BackupOperation.restore,
      previousSummary: prev,
    );

    try {
      final summary = coordinator.restoreBackup(
        current.pendingBackup,
        allowStale: true,
      );
      _state = BackupSuccess(
        operation: BackupOperation.restore,
        summary: summary,
        completedAtUtc: _clock().toUtc(),
      );
      return true;
    } on BackupException catch (e) {
      _state = BackupFailure(
        operation: BackupOperation.restore,
        message: e.message,
        path: e.path,
        previousSummary: prev,
      );
      return true;
    } catch (e) {
      _state = BackupFailure(
        operation: BackupOperation.restore,
        message: e.toString(),
        previousSummary: prev,
      );
      return true;
    } finally {
      _isBusy = false;
    }
  }

  /// Cancels a pending stale restore confirmation and resets state to idle.
  bool cancelStaleConfirmation() {
    if (_state is BackupStaleConfirmationRequired) {
      final summary = (_state as BackupStaleConfirmationRequired).summary;
      _state = BackupSuccess(
        operation: BackupOperation.inspect,
        summary: summary,
        completedAtUtc: _clock().toUtc(),
      );
      return true;
    }
    return false;
  }

  /// Restores directly from a parsed in-memory [CompanionBackup].
  bool restoreParsedBackup(CompanionBackup backup, {bool allowStale = false}) {
    if (_isBusy) return false;
    final prev = lastSummary;
    final currentRevision = coordinator.scheduleStore.knownRevision;

    if (!allowStale && backup.knownRevision < currentRevision) {
      _state = BackupStaleConfirmationRequired(
        pendingBackup: backup,
        summary: BackupSummary.fromBackup(backup),
        currentRevision: currentRevision,
        backupRevision: backup.knownRevision,
      );
      return true;
    }

    try {
      final summary = coordinator.restoreBackup(backup, allowStale: allowStale);
      _state = BackupSuccess(
        operation: BackupOperation.restore,
        summary: summary,
        completedAtUtc: _clock().toUtc(),
      );
      return true;
    } on BackupException catch (e) {
      _state = BackupFailure(
        operation: BackupOperation.restore,
        message: e.message,
        path: e.path,
        previousSummary: prev,
      );
      return true;
    }
  }

  /// Erases the saved local backup file. Transitions to [BackupAbsent].
  Future<bool> erase() async {
    if (_isBusy) return false;
    _isBusy = true;
    _state = const BackupBusy(operation: BackupOperation.erase);

    try {
      await coordinator.erase();
      _state = const BackupAbsent(operation: BackupOperation.erase);
      return true;
    } catch (e) {
      _state = BackupFailure(
        operation: BackupOperation.erase,
        message: e.toString(),
      );
      return true;
    } finally {
      _isBusy = false;
    }
  }
}
