/// Host-only presentation policy over the schedule exchange. No I/O or UI.
/// Returned envelopes are framed, not sent; pending means a request was built,
/// not delivered. Callers must authenticate/correlate incoming tokens/messages
/// and enforce device/session replay and timing policy. This controller cannot
/// establish device identity or receipt authenticity. Replay tracking is scoped
/// to one exchange and resets on fresh review; it is not session-wide security.
library;

import 'alarm_draft.dart';
import 'schedule_diff.dart';
import 'schedule_exchange.dart';
import 'schedule_store.dart';

enum ScheduleFlowPhase {
  idle,
  review,
  previewPending,
  confirmationRequired,
  applyPending,
  needsRefresh,
  applied,
  refused,
}

/// Immutable presentation snapshot; contains no token or request envelope.
class ScheduleFlowState {
  const ScheduleFlowState({
    required this.phase,
    this.diff,
    this.code,
    this.conflictRevision,
  });

  final ScheduleFlowPhase phase;
  final ScheduleDiff? diff;
  final String? code;
  final int? conflictRevision;

  bool get canPreview => phase == ScheduleFlowPhase.review;
  bool get canConfirm => phase == ScheduleFlowPhase.confirmationRequired;
  bool get canCancel => switch (phase) {
    ScheduleFlowPhase.review ||
    ScheduleFlowPhase.previewPending ||
    ScheduleFlowPhase.confirmationRequired ||
    ScheduleFlowPhase.refused => true,
    _ => false,
  };

  String get statusText => switch (phase) {
    ScheduleFlowPhase.idle => 'No proposal reviewed.',
    ScheduleFlowPhase.review => 'Review ready. No request sent.',
    ScheduleFlowPhase.previewPending =>
      'Preview framed. Awaiting caller-supplied token.',
    ScheduleFlowPhase.confirmationRequired =>
      'Explicit apply confirmation required.',
    ScheduleFlowPhase.applyPending =>
      'Apply framed. Awaiting receipt; device outcome unknown.',
    ScheduleFlowPhase.needsRefresh =>
      'Revision conflict. Refresh mirror and review again.',
    ScheduleFlowPhase.applied =>
      'Consistent supplied receipt adopted by local mirror.',
    ScheduleFlowPhase.refused => 'Proposal refused. Review again.',
  };
}

class ScheduleFlowController {
  ScheduleFlowController(this._store) : _exchange = ScheduleExchange(_store);

  final DeviceScheduleStore _store;
  ScheduleExchange _exchange;
  ScheduleFlowState _state = const ScheduleFlowState(
    phase: ScheduleFlowPhase.idle,
  );
  ScheduleFlowState get state => _state;

  /// Side-effect-free review of the mirror. While an exchange is pending,
  /// replacement reviews are refused rather than implicitly canceling it.
  bool review(Iterable<AlarmDraft> proposal) {
    if (!const {
      ScheduleFlowPhase.idle,
      ScheduleFlowPhase.review,
      ScheduleFlowPhase.refused,
      ScheduleFlowPhase.applied,
    }.contains(_state.phase)) {
      return false;
    }
    _exchange = ScheduleExchange(_store);
    try {
      final diff = diffSchedule(
        baseline: _store.committedAlarms,
        proposal: proposal,
        expectedRevision: _store.knownRevision,
      );
      _state = ScheduleFlowState(phase: ScheduleFlowPhase.review, diff: diff);
      return true;
    } on ArgumentError {
      _state = const ScheduleFlowState(
        phase: ScheduleFlowPhase.refused,
        code: 'invalid_proposal',
      );
      return false;
    }
  }

  Map<String, Object?>? requestPreview({
    required String messageId,
    required DateTime sentAt,
  }) {
    if (!_state.canPreview) return null;
    final diff = _state.diff!;
    if (_store.knownRevision != diff.expectedRevision) {
      _state = const ScheduleFlowState(
        phase: ScheduleFlowPhase.refused,
        code: 'mirror_changed',
      );
      return null;
    }
    // Recreate before framing so a rejected identity can be corrected without
    // leaving a partially armed exchange. No request has left this class.
    _exchange = ScheduleExchange(_store)..beginPreview(diff);
    try {
      final request = _exchange.buildPreview(
        messageId: messageId,
        sentAt: sentAt,
      );
      _move(ScheduleFlowPhase.previewPending);
      return request;
    } on ExchangeRejectException catch (e) {
      _move(ScheduleFlowPhase.review, code: e.code);
      return null;
    }
  }

  bool receiveToken(String token) {
    if (_state.phase != ScheduleFlowPhase.previewPending) return false;
    try {
      _exchange.receiveApplyToken(token);
      _move(ScheduleFlowPhase.confirmationRequired);
      return true;
    } on ArgumentError {
      _move(ScheduleFlowPhase.previewPending, code: 'invalid_apply_token');
      return false;
    }
  }

  /// This separate call is the only path that frames an apply. A token alone
  /// never applies. A framed apply cannot be canceled as a device rollback.
  Map<String, Object?>? confirmApply({
    required String messageId,
    required DateTime sentAt,
  }) {
    if (!_state.canConfirm) return null;
    if (_store.knownRevision != _state.diff!.expectedRevision) {
      _exchange.abort();
      _state = const ScheduleFlowState(
        phase: ScheduleFlowPhase.refused,
        code: 'mirror_changed',
      );
      return null;
    }
    try {
      final request = _exchange.buildApply(
        messageId: messageId,
        sentAt: sentAt,
      );
      _move(ScheduleFlowPhase.applyPending);
      return request;
    } on ExchangeRejectException catch (e) {
      _move(ScheduleFlowPhase.confirmationRequired, code: e.code);
      return null;
    }
  }

  IngestResult? receive(Map<String, Object?> payload) {
    if (_state.phase != ScheduleFlowPhase.applyPending) return null;
    // The domain gate accepts request types too; do not let an unexpected
    // response type throw or consume the exchange's inbound replay entry.
    if (payload['type'] != 'event.syncReceipt' &&
        payload['type'] != 'error.response') {
      const result = IngestResult(
        disposition: IngestDisposition.invalid,
        code: 'unexpected_response',
      );
      _move(ScheduleFlowPhase.applyPending, code: result.code);
      return result;
    }
    // A separately refreshed mirror makes old apply evidence ambiguous; keep
    // the pending outcome, do not adopt or retry. Reconciliation is external.
    if (_store.knownRevision != _state.diff!.expectedRevision) {
      const result = IngestResult(
        disposition: IngestDisposition.rejected,
        code: 'mirror_changed',
      );
      _move(ScheduleFlowPhase.applyPending, code: result.code);
      return result;
    }
    final result = _exchange.ingest(payload);
    switch (result.disposition) {
      case IngestDisposition.applied:
        _move(ScheduleFlowPhase.applied);
      case IngestDisposition.conflict:
        _state = ScheduleFlowState(
          phase: ScheduleFlowPhase.needsRefresh,
          code: result.code,
          conflictRevision: result.currentRevision,
        );
      case IngestDisposition.invalid:
      case IngestDisposition.rejected:
        _move(
          _exchange.phase == ExchangePhase.idle
              ? ScheduleFlowPhase.refused
              : ScheduleFlowPhase.applyPending,
          code: result.code,
        );
    }
    return result;
  }

  /// Acknowledge independent refresh only at the exact reported revision.
  /// Missing revision is deliberately unresolved (external reconciliation).
  /// No proposal/token survives this step; a new explicit review is required.
  bool acknowledgeRefresh() {
    if (_state.phase != ScheduleFlowPhase.needsRefresh ||
        _state.conflictRevision == null ||
        _store.knownRevision != _state.conflictRevision) {
      return false;
    }
    _exchange.rebase();
    _state = const ScheduleFlowState(phase: ScheduleFlowPhase.idle);
    return true;
  }

  bool cancel() {
    if (!_state.canCancel) return false;
    _exchange = ScheduleExchange(_store);
    _state = const ScheduleFlowState(phase: ScheduleFlowPhase.idle);
    return true;
  }

  void _move(ScheduleFlowPhase phase, {String? code}) {
    _state = ScheduleFlowState(phase: phase, diff: _state.diff, code: code);
  }
}
