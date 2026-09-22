/// Contract-checked framing of the `schedule.preview` / `schedule.apply`
/// exchange, apply-token binding, sync-receipt ingestion, and
/// `revision_conflict` handling for one device schedule mirror.
///
/// This is the domain half of the lost-update protection described in
/// `docs/protocol.md`: the app previews a proposal against the revision it
/// believes is committed, the device answers with an opaque apply token, the
/// apply re-sends the exact previewed content with `expectedRevision` and
/// that token, and the only accepted success evidence is an
/// `event.syncReceipt` advancing the revision by exactly one with a matching
/// alarm count. A `revision_conflict` error moves the exchange into a
/// refresh state instead of silently retrying against a stale revision.
///
/// Built request envelopes are self-checked through the same mirrored
/// contract gate (`validateContractMessage`) that firmware and the Python
/// mirror apply to the canonical fixtures, so a request the device would
/// refuse never leaves the domain layer. Inbound device messages are
/// validated through that gate with a bounded replay window before any
/// state changes.
///
/// Pure Dart, no I/O: no transport, pairing, filesystem, or UI. Message
/// identity (`messageId`, `sentAt`) is caller-supplied so framing stays
/// deterministic and testable; the apply token is opaque device data that is
/// length/charset bounded and never interpreted. The content binding between
/// a preview and its apply is by-construction: the armed proposal is an
/// unmodifiable list of immutable drafts, and the apply additionally
/// re-verifies the recomputed wire-body digest against the digest bound when
/// the token was received.
library;

import 'dart:convert';

import 'protocol_contract.dart';
import 'schedule_diff.dart';
import 'schedule_store.dart';

/// Charset mirrors the envelope `messageId` pattern — device-issued apply
/// tokens must fit the same wire shape (`preview-7f93d1` in the canonical
/// apply fixture).
final RegExp _applyTokenPattern = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

/// A stable error-model code from `docs/protocol.md` refused locally, e.g.
/// `invalid_message_id` when a caller-supplied envelope identity would not
/// survive the device-side contract gate.
class ExchangeRejectException implements Exception {
  const ExchangeRejectException(this.code, [this.detail = '']);

  /// Stable code name, e.g. `invalid_sent_at`.
  final String code;
  final String detail;

  @override
  String toString() =>
      'ExchangeRejectException($code${detail.isEmpty ? '' : ': $detail'})';
}

enum ExchangePhase {
  /// No armed proposal.
  idle,

  /// The preview request envelope was produced; awaiting the device's
  /// preview response carrying an apply token.
  previewSent,

  /// A bounded, charset-valid apply token is bound to the previewed
  /// content and revision; the apply request may be built.
  readyToApply,

  /// The apply request envelope was produced; awaiting the device's
  /// `event.syncReceipt` or `error.response`.
  applySent,

  /// The device reported `revision_conflict`; the mirror must be refreshed
  /// to the reported revision before a new preview may be armed.
  needsRefresh,

  /// A consistent sync receipt was ingested and the store adopted the
  /// applied revision. Terminal until [ScheduleExchange.reset].
  applied,
}

enum IngestDisposition {
  /// A consistent sync receipt was applied to the store.
  applied,

  /// The envelope failed the contract gate (shape, identity, replay, size).
  invalid,

  /// An `error.response` with `revision_conflict`; see `currentRevision`.
  conflict,

  /// Envelope-valid but domain-inconsistent receipt, or a terminal
  /// `error.response` other than `revision_conflict`.
  rejected,
}

/// Outcome of [ScheduleExchange.ingest]. [code] carries the stable
/// error-model code (`docs/protocol.md` "Error model") whenever the
/// disposition is not [IngestDisposition.applied].
class IngestResult {
  const IngestResult({
    required this.disposition,
    this.code,
    this.currentRevision,
  });

  final IngestDisposition disposition;
  final String? code;

  /// Present for [IngestDisposition.conflict] when the device supplied
  /// `currentRevision`.
  final int? currentRevision;
}

/// One preview→apply exchange against a [DeviceScheduleStore] mirror.
class ScheduleExchange {
  ScheduleExchange(this._store);

  final DeviceScheduleStore _store;
  final Set<String> _seenInboundMessageIds = {};

  ExchangePhase _phase = ExchangePhase.idle;
  ScheduleDiff? _armed;
  String? _boundToken;
  String? _boundDigest;
  int? _conflictRevision;

  ExchangePhase get phase => _phase;

  /// Revision this exchange was armed against, or null when unarmed.
  int? get expectedRevision => _armed?.expectedRevision;

  /// Deterministic digest of the armed wire-body content, or null. Used to
  /// verify the apply re-sends exactly what the token was bound to.
  String? get proposalDigest => _boundDigest;

  bool get hasBoundToken => _boundToken != null;

  /// Revision reported by the device in `revision_conflict`, if any.
  int? get conflictRevision => _conflictRevision;

  /// True once an `event.syncReceipt` has been ingested and adopted.
  bool get receiptApplied => _phase == ExchangePhase.applied;

  /// Arm a proposal for previewing. The diff must expect exactly the
  /// revision the local mirror currently holds — a stale proposal is
  /// refused before any envelope is built.
  void beginPreview(ScheduleDiff diff) {
    if (_phase != ExchangePhase.idle) {
      throw StateError('exchange is ${_phase.name}; abort or reset first');
    }
    if (_armed != null) {
      throw StateError('a proposal is already armed; abort first');
    }
    if (diff.expectedRevision != _store.knownRevision) {
      throw ArgumentError.value(
        diff.expectedRevision,
        'diff.expectedRevision',
        'proposal does not match mirror revision ${_store.knownRevision}; '
            'refresh the mirror first',
      );
    }
    _armed = diff;
    _boundDigest = _digest(diff.toWirePreviewBody());
  }

  /// Produce the `schedule.preview` request envelope.
  Map<String, Object?> buildPreview({
    required String messageId,
    required DateTime sentAt,
  }) {
    final diff = _requireArmed('buildPreview');
    if (_phase != ExchangePhase.idle) {
      throw StateError('preview request already built (${_phase.name})');
    }
    final envelope = _envelope(
      type: 'schedule.preview',
      messageId: messageId,
      sentAt: sentAt,
      expectedRevision: diff.expectedRevision,
      body: <String, Object?>{'alarms': diff.toWirePreviewBody()},
    );
    _phase = ExchangePhase.previewSent;
    return envelope;
  }

  /// Bind the device's preview-response apply token to the armed content
  /// and revision. The token stays inside the domain layer: transport
  /// belongs to a later slice.
  void receiveApplyToken(String token) {
    if (_phase != ExchangePhase.previewSent) {
      throw StateError(
        'apply token only binds after the preview request is built '
        '(${_phase.name})',
      );
    }
    if (!_applyTokenPattern.hasMatch(token) ||
        utf8.encode(token).length > 128) {
      throw ArgumentError.value(token, 'token', 'apply token shape invalid');
    }
    _boundToken = token;
    _phase = ExchangePhase.readyToApply;
  }

  /// Produce the `schedule.apply` request envelope carrying the bound token
  /// and the exact previewed alarm set.
  Map<String, Object?> buildApply({
    required String messageId,
    required DateTime sentAt,
  }) {
    final diff = _requireArmed('buildApply');
    if (_phase != ExchangePhase.readyToApply) {
      throw StateError('apply requires a bound token (${_phase.name})');
    }
    if (_store.knownRevision != diff.expectedRevision) {
      throw StateError(
        'mirror advanced to ${_store.knownRevision} while this exchange is '
        'bound to revision ${diff.expectedRevision}; refresh and re-preview',
      );
    }
    final alarms = diff.toWirePreviewBody();
    if (_digest(alarms) != _boundDigest) {
      throw StateError('previewed content drifted after token binding');
    }
    final envelope = _envelope(
      type: 'schedule.apply',
      messageId: messageId,
      sentAt: sentAt,
      expectedRevision: diff.expectedRevision,
      body: <String, Object?>{'applyToken': _boundToken, 'alarms': alarms},
    );
    _phase = ExchangePhase.applySent;
    return envelope;
  }

  /// Validate and act on one inbound device message
  /// (`event.syncReceipt` or `error.response`) through the mirrored
  /// contract gate with bounded replay tracking. No store mutation happens
  /// unless a fully consistent receipt passes every check.
  IngestResult ingest(Map<String, Object?> payload) {
    if (_phase != ExchangePhase.applySent) {
      throw StateError(
        'ingest only applies while awaiting the response '
        '(${_phase.name})',
      );
    }
    final gate = validateContractMessage(
      payload,
      replayWindow: _seenInboundMessageIds,
    );
    if (gate != ContractCode.accepted) {
      return IngestResult(
        disposition: IngestDisposition.invalid,
        code: contractCodeName(gate),
      );
    }
    final type = payload['type']! as String;
    final body = (payload['body']! as Map).cast<String, Object?>();
    if (type == 'event.syncReceipt') {
      return _ingestReceipt(body);
    }
    if (type == 'error.response') {
      return _ingestError(body);
    }
    throw ArgumentError.value(
      type,
      "payload['type']",
      'not an ingestable response type',
    );
  }

  IngestResult _ingestReceipt(Map<String, Object?> body) {
    final diff = _armed!;
    final appliedRevision = body['appliedRevision']! as int;
    final alarmCount = body['alarmCount']! as int;
    final nextAlarmUtc = DateTime.parse(body['nextAlarmUtc']! as String);
    // Optimistic-concurrency discipline from docs/protocol.md: the applied
    // revision must be exactly the one this apply proposed, and the count
    // must match what was previewed. Anything else is refused without
    // touching the store.
    if (appliedRevision != diff.expectedRevision + 1 ||
        alarmCount != diff.proposedOrder.length) {
      return const IngestResult(
        disposition: IngestDisposition.rejected,
        code: 'payload_semantic_error',
      );
    }
    _store.recordApplied(
      revision: appliedRevision,
      appliedAlarms: diff.proposedOrder,
      nextAlarmUtc: nextAlarmUtc,
    );
    // The token is single-use once its apply has been confirmed.
    _boundToken = null;
    _armed = null;
    _boundDigest = null;
    _phase = ExchangePhase.applied;
    return const IngestResult(disposition: IngestDisposition.applied);
  }

  IngestResult _ingestError(Map<String, Object?> body) {
    final code = body['code']! as String;
    final currentRevision = body['currentRevision'] as int?;
    _boundToken = null;
    _armed = null;
    _boundDigest = null;
    if (code == 'revision_conflict') {
      _conflictRevision = currentRevision;
      _phase = ExchangePhase.needsRefresh;
      return IngestResult(
        disposition: IngestDisposition.conflict,
        code: code,
        currentRevision: currentRevision,
      );
    }
    _conflictRevision = null;
    _phase = ExchangePhase.idle;
    return IngestResult(disposition: IngestDisposition.rejected, code: code);
  }

  /// Leave [ExchangePhase.needsRefresh] once the store mirror has been
  /// refreshed (by an independent sync path) to the revision the device
  /// reported. Refuses while the mirror is still stale, and refuses when
  /// the conflict carried no usable revision.
  void rebase() {
    if (_phase != ExchangePhase.needsRefresh) {
      throw StateError(
        'rebase only applies after a conflict '
        '(${_phase.name})',
      );
    }
    final revision = _conflictRevision;
    if (revision == null) {
      throw StateError(
        'conflict carried no currentRevision; abort and re-preview from '
        'a refreshed mirror',
      );
    }
    if (_store.knownRevision != revision) {
      throw StateError(
        'mirror is at ${_store.knownRevision}; rebase requires a refresh to '
        'revision $revision first',
      );
    }
    _conflictRevision = null;
    _phase = ExchangePhase.idle;
  }

  /// Abandon the armed exchange from any non-terminal phase and discard the
  /// bound token.
  void abort() {
    if (_phase == ExchangePhase.idle || _phase == ExchangePhase.applied) {
      throw StateError('nothing to abort (${_phase.name})');
    }
    _boundToken = null;
    _boundDigest = null;
    _armed = null;
    _conflictRevision = null;
    _phase = ExchangePhase.idle;
  }

  /// Return to [ExchangePhase.idle] after a completed exchange so the same
  /// instance can arm a new proposal.
  void reset() {
    if (_phase != ExchangePhase.applied) {
      throw StateError('only a completed exchange resets (${_phase.name})');
    }
    _phase = ExchangePhase.idle;
  }

  ScheduleDiff _requireArmed(String operation) {
    final diff = _armed;
    if (diff == null) {
      throw StateError('$operation requires an armed proposal');
    }
    return diff;
  }

  Map<String, Object?> _envelope({
    required String type,
    required String messageId,
    required DateTime sentAt,
    required int expectedRevision,
    required Map<String, Object?> body,
  }) {
    if (!_isBoundedMessageId(messageId)) {
      throw const ExchangeRejectException(
        'invalid_message_id',
        'message identity would not survive the contract gate',
      );
    }
    final sentAtText = _formatSentAt(sentAt);
    final envelope = <String, Object?>{
      'protocol': kProtocolVersion,
      'messageId': messageId,
      'sentAt': sentAtText,
      'type': type,
      'expectedRevision': expectedRevision,
      'body': body,
    };
    final code = validateContractMessage(envelope);
    if (code != ContractCode.accepted) {
      throw ExchangeRejectException(contractCodeName(code));
    }
    return Map.unmodifiable(envelope);
  }
}

bool _isBoundedMessageId(String messageId) =>
    messageId.length <= kMaxMessageIdBytes &&
    _messageIdPattern.hasMatch(messageId);

final RegExp _messageIdPattern = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

/// Strict envelope form `YYYY-MM-DDTHH:MM:SSZ` with no fractional seconds;
/// mirrors the `invalid_sent_at` boundary of the contract gate locally so
/// callers get an exception naming the stable code instead of an envelope
/// the device would refuse.
String _formatSentAt(DateTime sentAt) {
  final utc = sentAt.toUtc();
  if (utc.millisecond != 0 || utc.microsecond != 0) {
    throw const ExchangeRejectException(
      'invalid_sent_at',
      'envelope timestamps carry second precision only',
    );
  }
  String two(int v) => v.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}'
      '-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
}

/// Deterministic content digest of a wire body. `AlarmDraft.toWireAlarm()`
/// inserts keys in a fixed order, so `jsonEncode` of the identical
/// construction path is identical; the digest only ever compares two bodies
/// built through the same code path.
String _digest(List<Map<String, Object?>> alarms) => jsonEncode(alarms);
