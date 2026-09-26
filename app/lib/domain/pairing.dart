/// Host-tested pairing domain state machine (parent #6, slice #47).
///
/// Models the invariants `docs/threat-model.md` "Pairing and credential
/// storage" and `docs/protocol.md` "Pairing assumptions" require of the
/// companion side of a physical pairing ceremony, without any transport,
/// cryptography, or platform secure-storage implementation:
///
/// * Pairing is closed by default. [PairingCeremony] only exists once a
///   caller reports the device opened a window, and that window is bounded
///   to [kMaxPairingWindowSeconds] (120s per TM-01 / the protocol doc).
/// * A confirmation must match BOTH the device-displayed short code and its
///   fingerprint while the window is open, or it is rejected without
///   completing the ceremony.
/// * Repeated wrong confirmations close the ceremony after
///   [kMaxPairingAttempts] failures (TM-01's "5-attempt closure"), matching
///   the timeout closure so lockout and expiry are exposed identically.
/// * Rate limiting (attempt/window closure) never blocks anything outside
///   this domain object — there is no physical-control code here to delay,
///   consistent with TM-07 "lockout applies only to pairing". Enforcement
///   is per-ceremony-object: a caller that constructs a fresh ceremony
///   resets the count, and window checks follow the injected clock, so a
///   backward system-clock change can extend a window. Authoritative
///   attempt counting and monotonic window timing are device/session
///   responsibilities and remain open (see CONN-02 in the verification
///   matrix).
/// * A completed ceremony yields a [PairedDeviceRecord] carrying a
///   caller-supplied secure-storage reference token. This domain layer does
///   not validate that token's semantics — callers must provide only
///   non-secret references (for example key aliases), never raw credential
///   material. [PairedDeviceRecord.toDiagnosticMap] is the only
///   serialization and it never includes the token, confirmation code, or
///   fingerprint.
///
/// This is domain policy only: no Bluetooth/LAN sockets, no mDNS, no
/// Keychain/Keystore plugin call, no ESP32 protected storage, and no
/// authenticated-transport session. Real device interoperability and the
/// eventual ephemeral authenticated key exchange (`docs/threat-model.md`
/// "the eventual protocol must bind [the short code] to an ephemeral
/// authenticated key exchange") remain open.
library;

/// Maximum physical pairing window, mirroring the protocol doc and TM-01.
const int kMaxPairingWindowSeconds = 120;

/// Failed-confirmation ceiling before the ceremony closes, mirroring TM-01's
/// "5-attempt closure".
const int kMaxPairingAttempts = 5;

const int kMaxCandidateIdentityBytes = 64;
const int kMaxShortCodeBytes = 16;
const int kMaxFingerprintBytes = 64;
const int kMaxSecureStorageReferenceBytes = 128;
const int kMaxDiscoveryCandidates = 32;

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

/// How a [PairingCandidate] was found. `manual` covers a user-entered
/// address; `discovered` covers a caller-supplied mDNS/BLE advertisement
/// already resolved to an identity string — this domain layer performs no
/// actual network discovery.
enum CandidateSource { manual, discovered }

/// One device the user could attempt to pair with: an address/identity the
/// app knows about before any pairing ceremony starts. Deliberately carries
/// no credential or connection state.
class PairingCandidate {
  PairingCandidate({
    required this.identity,
    required this.displayName,
    required this.source,
  }) {
    _requireBounded(identity, kMaxCandidateIdentityBytes, 'identity');
    _requireBounded(displayName, kMaxCandidateIdentityBytes, 'displayName');
  }

  /// Stable local identifier: a manual address or a resolved discovery
  /// identity. Never a credential value.
  final String identity;
  final String displayName;
  final CandidateSource source;

  @override
  bool operator ==(Object other) =>
      other is PairingCandidate &&
      other.identity == identity &&
      other.displayName == displayName &&
      other.source == source;

  @override
  int get hashCode => Object.hash(identity, displayName, source);

  @override
  String toString() => 'PairingCandidate($identity, $source.name)';
}

/// Bounded, deduplicated registry of pairing candidates the app currently
/// knows about, keyed by [PairingCandidate.identity]. Ordering is stable
/// insertion order so a UI list does not jitter as duplicates upsert.
class PairingCandidateRegistry {
  final List<PairingCandidate> _candidates = [];

  List<PairingCandidate> get candidates => List.unmodifiable(_candidates);

  PairingCandidate? byIdentity(String identity) {
    for (final candidate in _candidates) {
      if (candidate.identity == identity) {
        return candidate;
      }
    }
    return null;
  }

  /// Adds or replaces by identity. Throws when the registry is full and the
  /// identity is new; replacing an existing identity never changes count.
  void upsert(PairingCandidate candidate) {
    final index = _candidates.indexWhere(
      (c) => c.identity == candidate.identity,
    );
    if (index >= 0) {
      _candidates[index] = candidate;
      return;
    }
    if (_candidates.length >= kMaxDiscoveryCandidates) {
      throw StateError('candidate registry is full ($kMaxDiscoveryCandidates)');
    }
    _candidates.add(candidate);
  }

  bool remove(String identity) {
    final before = _candidates.length;
    _candidates.removeWhere((c) => c.identity == identity);
    return _candidates.length != before;
  }

  void clear() => _candidates.clear();
}

/// Why a [PairingCeremony] is no longer accepting confirmations.
enum PairingClosureReason {
  /// The device-issued window elapsed before a successful confirmation.
  timedOut,

  /// [kMaxPairingAttempts] failed confirmations were made.
  attemptsExhausted,

  /// The caller explicitly cancelled the ceremony.
  cancelled,

  /// A confirmation matched and the ceremony completed successfully.
  confirmed,
}

/// Immutable outcome of one confirmation attempt.
class PairingAttemptResult {
  const PairingAttemptResult({
    required this.accepted,
    required this.attemptNumber,
    required this.remainingAttempts,
    this.closureReason,
  });

  /// True only when both the short code and fingerprint matched while the
  /// window was open.
  final bool accepted;

  /// 1-based count of this attempt within the ceremony.
  final int attemptNumber;

  /// Attempts left before [PairingClosureReason.attemptsExhausted]. Zero
  /// once the ceremony is closed for any reason.
  final int remainingAttempts;

  /// Set when this attempt closed the ceremony (success or exhaustion).
  final PairingClosureReason? closureReason;

  @override
  String toString() =>
      'PairingAttemptResult(accepted: $accepted, attempt: $attemptNumber, '
      'remaining: $remainingAttempts, closure: ${closureReason?.name})';
}

/// A single physical pairing ceremony against one candidate device.
///
/// Construct only once the device has reported an open window (`windowStart`
/// is the caller-supplied clock reading at that moment): this type has no
/// "not yet open" state because the app is not the one that opens the
/// window — the device is (per the threat model, pairing is closed by
/// default and the app cannot open it remotely).
class PairingCeremony {
  PairingCeremony({
    required this.candidate,
    required String expectedShortCode,
    required String expectedFingerprint,
    required DateTime windowStart,
    int windowSeconds = kMaxPairingWindowSeconds,
    DateTime Function()? clock,
  }) : _expectedShortCode = expectedShortCode,
       _expectedFingerprint = expectedFingerprint,
       _windowStart = windowStart.toUtc(),
       _windowSeconds = windowSeconds,
       _clock = clock ?? DateTime.now {
    _requireBounded(expectedShortCode, kMaxShortCodeBytes, 'shortCode');
    _requireBounded(expectedFingerprint, kMaxFingerprintBytes, 'fingerprint');
    if (windowSeconds <= 0 || windowSeconds > kMaxPairingWindowSeconds) {
      throw ArgumentError.value(
        windowSeconds,
        'windowSeconds',
        'must be in 1..$kMaxPairingWindowSeconds',
      );
    }
  }

  final PairingCandidate candidate;
  final String _expectedShortCode;
  final String _expectedFingerprint;
  final DateTime _windowStart;
  final int _windowSeconds;
  final DateTime Function() _clock;

  int _attempts = 0;
  PairingClosureReason? _closureReason;
  bool _recordCompleted = false;

  /// True once the ceremony can no longer accept confirmations, whether by
  /// success, exhaustion, expiry, or explicit cancellation.
  bool get isClosed => _closureReason != null;

  PairingClosureReason? get closureReason => _closureReason;

  int get attemptCount => _attempts;

  int get remainingAttempts => isClosed ? 0 : kMaxPairingAttempts - _attempts;

  DateTime get windowStart => _windowStart;

  DateTime get windowDeadline =>
      _windowStart.add(Duration(seconds: _windowSeconds));

  /// Seconds remaining in the window as of the injected clock, clamped to
  /// zero. Does not itself close the ceremony — call [attemptConfirmation]
  /// or [checkExpiry] to observe a closure transition.
  int remainingWindowSeconds() {
    final now = _clock().toUtc();
    final remaining = windowDeadline.difference(now).inSeconds;
    if (remaining < 0) return 0;
    if (remaining > _windowSeconds) return _windowSeconds;
    return remaining;
  }

  bool _hasStartedAt(DateTime now) => !now.isBefore(_windowStart);

  bool _isExpiredAt(DateTime now) => !now.isBefore(windowDeadline);

  /// Closes the ceremony with [PairingClosureReason.timedOut] if the window
  /// has elapsed and it is not already closed. Returns true if this call
  /// performed the closure. Safe to call repeatedly / defensively before an
  /// attempt.
  bool checkExpiry() {
    if (isClosed) {
      return false;
    }
    if (_isExpiredAt(_clock().toUtc())) {
      _closureReason = PairingClosureReason.timedOut;
      return true;
    }
    return false;
  }

  /// Explicitly abandons the ceremony. A no-op if already closed (keeps
  /// the original closure reason rather than overwriting it).
  void cancel() {
    if (isClosed) {
      return;
    }
    _closureReason = PairingClosureReason.cancelled;
  }

  /// Attempts to confirm the ceremony with a code/fingerprint pair the user
  /// (or a UI reading a device screen) supplied. Throws [StateError] if the
  /// ceremony is already closed — callers must check [isClosed] first,
  /// mirroring how a real UI would disable the confirm action.
  PairingAttemptResult attemptConfirmation({
    required String shortCode,
    required String fingerprint,
  }) {
    if (isClosed) {
      throw StateError(
        'ceremony already closed (${_closureReason!.name}); '
        'no further attempts are accepted',
      );
    }
    final now = _clock().toUtc();
    if (!_hasStartedAt(now)) {
      // Fail closed before the device window opens: consume no attempt and
      // keep the ceremony open so a premature caller cannot pre-confirm.
      throw StateError(
        'pairing window has not opened yet; confirmation is not accepted',
      );
    }
    if (_isExpiredAt(now)) {
      _closureReason = PairingClosureReason.timedOut;
      throw StateError('pairing window elapsed before this attempt was made');
    }

    _attempts += 1;
    final matched =
        shortCode == _expectedShortCode && fingerprint == _expectedFingerprint;

    if (matched) {
      _closureReason = PairingClosureReason.confirmed;
      return PairingAttemptResult(
        accepted: true,
        attemptNumber: _attempts,
        remainingAttempts: 0,
        closureReason: PairingClosureReason.confirmed,
      );
    }

    final remaining = kMaxPairingAttempts - _attempts;
    if (remaining <= 0) {
      _closureReason = PairingClosureReason.attemptsExhausted;
      return PairingAttemptResult(
        accepted: false,
        attemptNumber: _attempts,
        remainingAttempts: 0,
        closureReason: PairingClosureReason.attemptsExhausted,
      );
    }

    return PairingAttemptResult(
      accepted: false,
      attemptNumber: _attempts,
      remainingAttempts: remaining,
    );
  }

  /// Builds the paired-device record after a successful confirmation. The
  /// [secureStorageReference] is an opaque token a later platform-storage
  /// slice would obtain from Keychain/Keystore/ESP32 protected storage after
  /// installing the real credential material there — this domain layer
  /// never sees or models the credential itself.
  PairedDeviceRecord completeWithReference({
    required String secureStorageReference,
    DateTime? pairedAtUtc,
  }) {
    if (_closureReason != PairingClosureReason.confirmed) {
      throw StateError(
        'ceremony has not been confirmed (state: '
        '${_closureReason?.name ?? 'open'})',
      );
    }
    if (_recordCompleted) {
      throw StateError('paired record already completed for this ceremony');
    }
    // Construct and fully validate before consuming this ceremony's one-shot
    // completion. A caller that passes an invalid opaque reference may fix the
    // local input and retry without repeating the physical pairing ceremony.
    final record = PairedDeviceRecord(
      identity: candidate.identity,
      displayName: candidate.displayName,
      secureStorageReference: secureStorageReference,
      pairedAtUtc: (pairedAtUtc ?? _clock()).toUtc(),
    );
    _recordCompleted = true;
    return record;
  }
}

/// The durable result of a completed pairing ceremony: a device identity
/// plus a reference to wherever the real credential material lives on the
/// platform.
///
/// Important boundary: [secureStorageReference] is just a bounded string in
/// this pure domain model. It is intended to be an alias/handle (for example
/// a Keychain/Keystore key name), but this class cannot prove that at runtime.
/// Adapters that bridge to platform storage must enforce alias semantics and
/// must never pass raw credentials here. TM-08/TM-14 risk reduction in this
/// slice comes from two properties: diagnostics/export omit this field, and no
/// dedicated credential fields are modeled.
class PairedDeviceRecord {
  PairedDeviceRecord({
    required this.identity,
    required this.displayName,
    required this.secureStorageReference,
    required this.pairedAtUtc,
  }) {
    _requireBounded(identity, kMaxCandidateIdentityBytes, 'identity');
    _requireBounded(displayName, kMaxCandidateIdentityBytes, 'displayName');
    _requireBounded(
      secureStorageReference,
      kMaxSecureStorageReferenceBytes,
      'secureStorageReference',
    );
  }

  final String identity;
  final String displayName;

  /// Pointer into platform secure storage, intended to be only an
  /// alias/handle (e.g. a Keychain/Keystore key name). This class cannot
  /// verify that: the constructor accepts any bounded string, so a caller
  /// could pass raw credential material here. Storage adapters must enforce
  /// alias semantics before constructing this record.
  final String secureStorageReference;

  final DateTime pairedAtUtc;

  /// Projection for logs/diagnostics/export: identity, display name, and
  /// pairing time only. [secureStorageReference] is intentionally excluded
  /// because it is a pointer to credential material with no purpose outside
  /// platform storage APIs — excluding it also protects the case where a
  /// caller misused the field to carry a raw secret.
  Map<String, Object?> toDiagnosticMap() => {
    'identity': identity,
    'displayName': displayName,
    'pairedAtUtc': pairedAtUtc.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is PairedDeviceRecord &&
      other.identity == identity &&
      other.displayName == displayName &&
      other.secureStorageReference == secureStorageReference &&
      other.pairedAtUtc == pairedAtUtc;

  @override
  int get hashCode =>
      Object.hash(identity, displayName, secureStorageReference, pairedAtUtc);

  @override
  String toString() =>
      'PairedDeviceRecord($identity, pairedAtUtc: $pairedAtUtc)';
}

/// Bounded registry of completed pairings, keyed by device identity. This is
/// the app-side mirror of "Users can list/revoke paired clients locally" —
/// revocation here only removes the local reference/record; it never
/// contacts the device or the platform secure-storage API, both of which
/// remain a later slice.
class PairedDeviceRegistry {
  final List<PairedDeviceRecord> _records = [];

  List<PairedDeviceRecord> get records => List.unmodifiable(_records);

  PairedDeviceRecord? byIdentity(String identity) {
    for (final record in _records) {
      if (record.identity == identity) {
        return record;
      }
    }
    return null;
  }

  void add(PairedDeviceRecord record) {
    final index = _records.indexWhere((r) => r.identity == record.identity);
    if (index >= 0) {
      _records[index] = record;
      return;
    }
    if (_records.length >= kMaxDiscoveryCandidates) {
      throw StateError('paired registry is full ($kMaxDiscoveryCandidates)');
    }
    _records.add(record);
  }

  /// Removes the local record for [identity]. Returns true if a record was
  /// present. This is local bookkeeping only — it does not revoke anything
  /// on the device or in platform secure storage.
  bool revoke(String identity) {
    final before = _records.length;
    _records.removeWhere((r) => r.identity == identity);
    return _records.length != before;
  }

  /// Mirrors "Factory reset revokes all pairings": clears every local
  /// record. Still local-only; does not perform the device-side reset.
  void clear() => _records.clear();
}
