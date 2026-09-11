#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace dawn {

constexpr std::int64_t kLateGraceSeconds = 10 * 60;
constexpr std::int64_t kDefaultSnoozeSeconds = 9 * 60;
constexpr std::int64_t kMinimumSnoozeSeconds = 1 * 60;
constexpr std::int64_t kMaximumSnoozeSeconds = 30 * 60;
constexpr std::int64_t kOccurrenceLifetimeSeconds = 60 * 60;
constexpr std::uint8_t kMaximumSnoozes = 6;
// Embedded persistence retains 32 recent diagnostic records and terminal
// high-watermarks for at most 32 distinct alarm IDs.
constexpr std::size_t kRecentTerminalRetention = 32;
constexpr std::size_t kTerminalHighWatermarkCapacity = 32;

enum class EvaluationStatus {
  disabled,
  armed,
  ringing,
  snoozed,
  dismissed,
  timed_out,
  missed,
  invalid_time,
  duplicate,
  conflict,
  invalid_request,
  snooze_limit_reached,
};

enum class TerminalReason {
  dismissed,
  alarm_disabled,
  timed_out,
  forward_jump,
  invalid_time,
  prolonged_power_off,
};

struct AlarmDefinition {
  std::string id;
  std::uint64_t schedule_revision{};
  bool enabled{};
  std::int64_t scheduled_utc_seconds{};
};

struct ActiveOccurrence {
  std::string alarm_id;
  std::string occurrence_id;
  std::int64_t scheduled_utc_seconds{};
  std::int64_t first_ring_utc_seconds{};
  std::int64_t first_ring_monotonic_seconds{};
  std::optional<std::int64_t> snooze_deadline_monotonic_seconds;
  std::uint8_t snooze_count{};
  bool recovered_after_reboot{};
  std::string last_recovery_boot_id;
};

struct TerminalOccurrence {
  std::string occurrence_id;
  TerminalReason reason{};
};

struct TerminalHighWatermark {
  std::string alarm_id;
  std::int64_t scheduled_utc_seconds{};
};

struct PersistentAlarmState {
  std::optional<ActiveOccurrence> active;
  std::vector<TerminalOccurrence> terminal;
  std::vector<TerminalHighWatermark> terminal_high_watermarks;
};

struct EvaluationResult {
  EvaluationStatus status{EvaluationStatus::armed};
  std::string occurrence_id;
  bool start_alert{};
  bool stop_alert{};
  bool persist_before_effects{};
  bool late{};
  std::int64_t lateness_seconds{};
  bool recovered_after_reboot{};
};

[[nodiscard]] std::string make_occurrence_id(const AlarmDefinition& alarm);

[[nodiscard]] EvaluationResult evaluate_due(
    const AlarmDefinition& alarm, PersistentAlarmState& state,
    std::int64_t wall_utc_seconds, std::int64_t monotonic_seconds,
    bool time_valid = true);

[[nodiscard]] EvaluationResult request_snooze(
    PersistentAlarmState& state, const std::string& occurrence_id,
    std::int64_t monotonic_seconds,
    std::int64_t duration_seconds = kDefaultSnoozeSeconds);

[[nodiscard]] EvaluationResult advance_active(PersistentAlarmState& state,
                                              std::int64_t monotonic_seconds);

[[nodiscard]] EvaluationResult dismiss_active(
    PersistentAlarmState& state, const std::string& occurrence_id,
    bool alarm_disabled = false);

[[nodiscard]] EvaluationResult recover_after_reboot(
    PersistentAlarmState& state, std::int64_t wall_utc_seconds,
    const std::string& boot_id);

// True when the state can durably journal a terminal outcome for
// `alarm_id`: either the alarm already carries a terminal high-watermark
// or the watermark table still has capacity. Callers that batch journal
// records must check every alarm up front and fail closed when any alarm
// cannot be tracked.
[[nodiscard]] bool journal_can_accept(const PersistentAlarmState& state,
                                      const std::string& alarm_id);

// Appends a terminal record with the given reason and raises the alarm's
// terminal high-watermark, reusing the engine's dedup and retention
// rules. Returns false without mutating the state when the watermark
// table is full, so batched journaling stays all-or-nothing.
[[nodiscard]] bool journal_terminal(
    PersistentAlarmState& state, const std::string& alarm_id,
    const std::string& occurrence_id, std::int64_t scheduled_utc_seconds,
    TerminalReason reason);

// Places a recovered late ring into the active slot after an invalid
// interval, recording the actual resume instants. Fails closed without
// mutation when the active slot is occupied or the alarm's terminal
// outcome could not be tracked afterwards.
[[nodiscard]] bool begin_recovered_ring(
    PersistentAlarmState& state, const std::string& alarm_id,
    const std::string& occurrence_id, std::int64_t scheduled_utc_seconds,
    std::int64_t wall_utc_seconds, std::int64_t monotonic_seconds);

}  // namespace dawn
