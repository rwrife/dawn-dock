#include "dawn/schedule_store.hpp"

#include <array>
#include <cstddef>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace {

int failures = 0;

void expect(bool condition, std::string_view message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

class MemorySlotStorage final : public dawn::SlotStorage {
public:
  bool begin_transaction() override {
    ++transaction_attempts;
    if (transaction_open) {
      return false;
    }
    transaction_open = true;
    return true;
  }

  void end_transaction() override { transaction_open = false; }

  [[nodiscard]] dawn::SlotReadResult
  read(dawn::StorageSlot slot) const override {
    if (fail_next_read && *fail_next_read == slot) {
      fail_next_read.reset();
      return {.status = dawn::SlotReadStatus::io_error, .bytes = {}};
    }
    const auto &record = slots_[index(slot)];
    if (!record) {
      return {.status = dawn::SlotReadStatus::empty, .bytes = {}};
    }
    return {.status = dawn::SlotReadStatus::present, .bytes = *record};
  }

  bool write(dawn::StorageSlot slot,
             std::span<const std::byte> bytes) override {
    ++write_attempts;
    if (!transaction_open) {
      write_without_transaction = true;
      return false;
    }
    if (fail_next_write) {
      fail_next_write = false;
      return false;
    }
    slots_[index(slot)] = std::vector<std::byte>(bytes.begin(), bytes.end());
    if (corrupt_next_write && !slots_[index(slot)]->empty()) {
      slots_[index(slot)]->back() ^= std::byte{0x01};
      corrupt_next_write = false;
    }
    ++write_count;
    last_written = slot;
    if (on_write) {
      on_write();
    }
    return true;
  }

  mutable std::optional<dawn::StorageSlot> fail_next_read;
  std::function<void()> on_write;
  int transaction_attempts{};
  int write_attempts{};
  int write_count{};
  bool transaction_open{};
  bool write_without_transaction{};
  bool fail_next_write{};
  bool corrupt_next_write{};
  dawn::StorageSlot last_written{dawn::StorageSlot::a};

  [[nodiscard]] std::vector<std::byte> copy(dawn::StorageSlot slot) const {
    const auto &record = slots_[index(slot)];
    return record.value_or(std::vector<std::byte>{});
  }

  void seed(dawn::StorageSlot slot, std::vector<std::byte> bytes) {
    slots_[index(slot)] = std::move(bytes);
  }

  void corrupt_byte(dawn::StorageSlot slot, std::size_t offset) {
    auto &record = slots_[index(slot)];
    if (record && offset < record->size()) {
      (*record)[offset] ^= std::byte{0x01};
    }
  }

  void corrupt_last_byte(dawn::StorageSlot slot) {
    auto &record = slots_[index(slot)];
    if (record && !record->empty()) {
      corrupt_byte(slot, record->size() - 1U);
    }
  }

private:
  static constexpr std::size_t index(dawn::StorageSlot slot) {
    return slot == dawn::StorageSlot::a ? 0U : 1U;
  }

  std::array<std::optional<std::vector<std::byte>>, 2> slots_;
};

dawn::ScheduleSnapshot make_snapshot(std::uint64_t revision) {
  dawn::ScheduleSnapshot snapshot;
  snapshot.revision = revision;
  snapshot.timezone_rules_version = "2026a";
  snapshot.alarms.push_back({
      .id = "weekday-wake",
      .schedule_revision = revision,
      .enabled = true,
      .scheduled_utc_seconds = 1'800'000'000,
  });
  return snapshot;
}

std::uint32_t current_record_crc(std::span<const std::byte> bytes) {
  auto crc = 0xffffffffU;
  const auto update = [&crc](std::span<const std::byte> part) {
    for (const auto byte : part) {
      crc ^= std::to_integer<std::uint8_t>(byte);
      for (int bit = 0; bit < 8; ++bit) {
        const auto mask =
            static_cast<std::uint32_t>(-static_cast<std::int32_t>(crc & 1U));
        crc = (crc >> 1U) ^ (0xedb88320U & mask);
      }
    }
  };
  update(bytes.subspan(4, 16));
  update(bytes.subspan(24));
  return ~crc;
}

void set_little_endian_u32(std::vector<std::byte> &bytes, std::size_t offset,
                           std::uint32_t value) {
  for (std::size_t index = 0; index < sizeof(value); ++index) {
    bytes[offset + index] =
        static_cast<std::byte>((value >> (index * 8U)) & 0xffU);
  }
}

void first_commit_round_trips_after_readback_validation() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  const auto snapshot = make_snapshot(1);

  const auto saved = store.save(snapshot, 0);
  const auto loaded = store.load();

  expect(saved.status == dawn::StoreStatus::stored,
         "first valid revision is stored");
  expect(saved.generation == 1, "first commit uses generation one");
  expect(backend.write_count == 1,
         "first commit writes exactly one redundant slot");
  expect(backend.last_written == dawn::StorageSlot::a,
         "first commit starts in slot A");
  expect(loaded.status == dawn::LoadStatus::loaded,
         "written snapshot loads successfully");
  expect(loaded.generation == 1, "load returns committed generation");
  expect(loaded.snapshot.revision == 1,
         "load returns committed schedule revision");
  expect(loaded.snapshot.timezone_rules_version == "2026a",
         "load returns pinned timezone rules version");
  expect(loaded.snapshot.alarms.size() == 1 &&
             loaded.snapshot.alarms.front().id == "weekday-wake" &&
             loaded.snapshot.alarms.front().enabled &&
             loaded.snapshot.alarms.front().scheduled_utc_seconds ==
                 1'800'000'000,
         "load returns the complete committed alarm");
}

void newest_corruption_rolls_back_with_visible_diagnostic() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  (void)store.save(make_snapshot(1), 0);
  (void)store.save(make_snapshot(2), 1);
  backend.corrupt_last_byte(dawn::StorageSlot::b);

  const auto loaded = store.load();

  expect(loaded.status == dawn::LoadStatus::loaded,
         "an older valid slot remains loadable");
  expect(loaded.snapshot.revision == 1 && loaded.generation == 1,
         "load selects the last-known-good generation");
  expect(loaded.source == dawn::StorageSlot::a,
         "recovery identifies the surviving slot");
  expect(loaded.corruption_detected,
         "fallback is surfaced as corruption recovery");
}

void identical_retry_does_not_consume_another_write() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  const auto snapshot = make_snapshot(1);
  (void)store.save(snapshot, 0);

  const auto retried = store.save(snapshot, 0);

  expect(retried.status == dawn::StoreStatus::unchanged,
         "acknowledgement-loss retry is idempotent");
  expect(retried.generation == 1,
         "idempotent retry keeps the committed generation");
  expect(backend.write_count == 1,
         "idempotent retry performs no additional slot write");
}

std::vector<std::byte> legacy_v1_record() {
  return {
      std::byte{0x44}, std::byte{0x44}, std::byte{0x53}, std::byte{0x54},
      std::byte{0x01}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x07}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x2e}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x7b}, std::byte{0x2c}, std::byte{0x14}, std::byte{0x58},
      std::byte{0x01}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x01}, std::byte{0x00}, std::byte{0x0c}, std::byte{0x00},
      std::byte{0x77}, std::byte{0x65}, std::byte{0x65}, std::byte{0x6b},
      std::byte{0x64}, std::byte{0x61}, std::byte{0x79}, std::byte{0x2d},
      std::byte{0x77}, std::byte{0x61}, std::byte{0x6b}, std::byte{0x65},
      std::byte{0x01}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x01}, std::byte{0x00}, std::byte{0xd2}, std::byte{0x49},
      std::byte{0x6b}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
      std::byte{0x00}, std::byte{0x00},
  };
}

void legacy_schema_loads_with_explicit_migration_marker() {
  MemorySlotStorage backend;
  backend.seed(dawn::StorageSlot::a, legacy_v1_record());
  dawn::AtomicScheduleStore store(backend);

  const auto loaded = store.load();

  expect(loaded.status == dawn::LoadStatus::loaded,
         "valid legacy schema remains recoverable");
  expect(loaded.migrated, "legacy schema is identified as migrated");
  expect(loaded.generation == 7 && loaded.snapshot.revision == 1,
         "legacy generation and schedule revision are preserved");
  expect(loaded.snapshot.timezone_rules_version == "legacy-v1-unpinned",
         "migration makes missing timezone provenance explicit");
  expect(loaded.snapshot.alarms.size() == 1 &&
             loaded.snapshot.alarms.front().id == "weekday-wake",
         "legacy alarm data survives migration");
}

void legacy_migration_commits_to_opposite_slot_with_rollback() {
  MemorySlotStorage backend;
  backend.seed(dawn::StorageSlot::a, legacy_v1_record());
  dawn::AtomicScheduleStore store(backend);

  const auto migrated = store.migrate_to_current_schema();
  const auto loaded = store.load();

  expect(migrated.status == dawn::StoreStatus::stored,
         "legacy snapshot is atomically rewritten");
  expect(migrated.generation == 8 &&
             migrated.destination == dawn::StorageSlot::b,
         "migration advances generation in the opposite slot");
  expect(backend.write_count == 1,
         "migration performs one verified slot write");
  expect(loaded.status == dawn::LoadStatus::loaded && !loaded.migrated &&
             loaded.generation == 8 && loaded.source == dawn::StorageSlot::b,
         "subsequent load selects the current-schema migration");

  backend.corrupt_last_byte(dawn::StorageSlot::b);
  const auto rolled_back = store.load();
  expect(rolled_back.status == dawn::LoadStatus::loaded &&
             rolled_back.migrated && rolled_back.generation == 7 &&
             rolled_back.corruption_detected,
         "failed migrated record rolls back to the intact legacy slot");
}

void oversized_occurrence_state_is_rejected_before_write() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  auto snapshot = make_snapshot(1);
  dawn::ActiveOccurrence active;
  active.alarm_id = std::string(dawn::kMaximumAlarmIdBytes + 1U, 'a');
  active.occurrence_id = "oversized:1:1800000000";
  snapshot.occurrence_state.active = std::move(active);

  const auto rejected = store.save(snapshot, 0);

  expect(rejected.status == dawn::StoreStatus::invalid_snapshot,
         "oversized active alarm ID fails semantic validation");
  expect(backend.write_count == 0,
         "invalid occurrence state is rejected before storage I/O");
}

void future_schema_fails_closed_without_reclassification() {
  MemorySlotStorage producer;
  dawn::AtomicScheduleStore producer_store(producer);
  (void)producer_store.save(make_snapshot(1), 0);
  auto future = producer.copy(dawn::StorageSlot::a);
  future[4] = std::byte{0x03};
  set_little_endian_u32(future, 20, current_record_crc(future));
  MemorySlotStorage backend;
  backend.seed(dawn::StorageSlot::a, std::move(future));
  dawn::AtomicScheduleStore store(backend);

  const auto loaded = store.load();
  const auto attempted_save = store.save(make_snapshot(1), 0);

  expect(loaded.status == dawn::LoadStatus::unsupported_schema,
         "newer intact schema is distinguished from corruption");
  expect(attempted_save.status == dawn::StoreStatus::corrupt_store,
         "old firmware refuses to overwrite a newer schema");
  expect(backend.write_count == 0,
         "unsupported schema causes no storage mutation");
}

void equal_generation_split_brain_fails_closed() {
  MemorySlotStorage first_backend;
  dawn::AtomicScheduleStore first_store(first_backend);
  (void)first_store.save(make_snapshot(1), 0);

  MemorySlotStorage second_backend;
  dawn::AtomicScheduleStore second_store(second_backend);
  auto different = make_snapshot(1);
  different.alarms.front().id = "different-alarm";
  (void)second_store.save(different, 0);

  MemorySlotStorage split_backend;
  split_backend.seed(dawn::StorageSlot::a,
                     first_backend.copy(dawn::StorageSlot::a));
  split_backend.seed(dawn::StorageSlot::b,
                     second_backend.copy(dawn::StorageSlot::a));
  dawn::AtomicScheduleStore split_store(split_backend);

  const auto loaded = split_store.load();
  const auto attempted_save = split_store.save(make_snapshot(2), 1);

  expect(loaded.status == dawn::LoadStatus::ambiguous,
         "same-generation divergent records are ambiguous");
  expect(attempted_save.status == dawn::StoreStatus::corrupt_store,
         "split-brain store cannot be advanced automatically");
  expect(split_backend.write_count == 0,
         "split-brain detection performs no storage mutation");
}

void complete_occurrence_journal_round_trips() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  auto snapshot = make_snapshot(1);
  snapshot.occurrence_state.active = dawn::ActiveOccurrence{
      .alarm_id = "weekday-wake",
      .occurrence_id = "weekday-wake:1:1800000000",
      .scheduled_utc_seconds = 1'800'000'000,
      .first_ring_utc_seconds = 1'800'000'005,
      .first_ring_monotonic_seconds = 40,
      .snooze_deadline_monotonic_seconds = 580,
      .snooze_count = 2,
      .recovered_after_reboot = true,
      .last_recovery_boot_id = "boot-42",
  };
  snapshot.occurrence_state.terminal.push_back(
      {.occurrence_id = "older:1:1700000000",
       .reason = dawn::TerminalReason::dismissed});
  snapshot.occurrence_state.terminal_high_watermarks.push_back(
      {.alarm_id = "older", .scheduled_utc_seconds = 1'700'000'000});

  const auto saved = store.save(snapshot, 0);
  const auto loaded = store.load();

  expect(saved.status == dawn::StoreStatus::stored &&
             loaded.status == dawn::LoadStatus::loaded,
         "complete occurrence journal stores and loads");
  expect(loaded.snapshot.occurrence_state.active &&
             loaded.snapshot.occurrence_state.active->snooze_count == 2 &&
             loaded.snapshot.occurrence_state.active
                     ->snooze_deadline_monotonic_seconds == 580 &&
             loaded.snapshot.occurrence_state.active->last_recovery_boot_id ==
                 "boot-42",
         "active reboot and snooze state round-trips");
  expect(loaded.snapshot.occurrence_state.terminal.size() == 1 &&
             loaded.snapshot.occurrence_state.terminal.front().reason ==
                 dawn::TerminalReason::dismissed,
         "terminal outcome round-trips");
  expect(loaded.snapshot.occurrence_state.terminal_high_watermarks.size() ==
                 1 &&
             loaded.snapshot.occurrence_state.terminal_high_watermarks.front()
                     .scheduled_utc_seconds == 1'700'000'000,
         "terminal duplicate-suppression watermark round-trips");
}

void revision_conflicts_and_skips_fail_before_io() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  (void)store.save(make_snapshot(1), 0);

  const auto stale = store.save(make_snapshot(2), 0);
  const auto skipped = store.save(make_snapshot(3), 1);

  expect(stale.status == dawn::StoreStatus::revision_conflict,
         "stale expected revision fails compare-and-swap");
  expect(skipped.status == dawn::StoreStatus::invalid_snapshot,
         "non-sequential revision is rejected");
  expect(backend.write_count == 1,
         "revision failures perform no additional write");
}

void torn_write_preserves_last_known_good() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  (void)store.save(make_snapshot(1), 0);
  backend.corrupt_next_write = true;

  const auto failed = store.save(make_snapshot(2), 1);
  const auto loaded = store.load();

  expect(failed.status == dawn::StoreStatus::verification_failed,
         "corrupted read-back prevents commit acknowledgement");
  expect(loaded.status == dawn::LoadStatus::loaded &&
             loaded.snapshot.revision == 1 && loaded.corruption_detected,
         "torn write leaves the prior generation loadable and visible");
}

void read_failure_never_becomes_empty_or_last_known_good() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  (void)store.save(make_snapshot(1), 0);

  backend.fail_next_read = dawn::StorageSlot::a;
  const auto loaded = store.load();
  backend.fail_next_read = dawn::StorageSlot::a;
  const auto attempted_save = store.save(make_snapshot(2), 1);

  expect(loaded.status == dawn::LoadStatus::io_error,
         "slot read failure is distinct from an empty slot");
  expect(attempted_save.status == dawn::StoreStatus::io_error,
         "save fails closed when either slot cannot be inspected");
  expect(backend.write_count == 1,
         "read failure cannot trigger overwrite of another slot");
}

void concurrent_writer_is_rejected_by_backend_transaction() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore first(backend);
  dawn::AtomicScheduleStore second(backend);
  std::optional<dawn::StoreStatus> interleaved_status;
  backend.on_write = [&] {
    interleaved_status = second.save(make_snapshot(1), 0).status;
  };

  const auto committed = first.save(make_snapshot(1), 0);

  expect(committed.status == dawn::StoreStatus::stored,
         "transaction owner completes its commit");
  expect(interleaved_status == dawn::StoreStatus::io_error,
         "interleaved writer cannot enter the active transaction");
  expect(backend.write_count == 1 && backend.transaction_attempts == 2,
         "only one serialized write reaches the backend");
  expect(!backend.transaction_open && !backend.write_without_transaction,
         "transaction is released and all writes were protected");
}

void generation_header_corruption_cannot_change_slot_selection() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  (void)store.save(make_snapshot(1), 0);
  (void)store.save(make_snapshot(2), 1);
  backend.corrupt_byte(dawn::StorageSlot::b, 8);

  const auto loaded = store.load();

  expect(
      loaded.status == dawn::LoadStatus::loaded &&
          loaded.snapshot.revision == 1 && loaded.generation == 1,
      "generation bit flip invalidates the record and selects last-known-good");
  expect(loaded.corruption_detected,
         "header corruption is surfaced as degraded redundancy");
}

void persisted_write_with_lost_readback_is_idempotent_on_retry() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  const auto snapshot = make_snapshot(1);
  backend.on_write = [&] { backend.fail_next_read = backend.last_written; };

  const auto uncertain = store.save(snapshot, 0);
  const auto retried = store.save(snapshot, 0);

  expect(uncertain.status == dawn::StoreStatus::io_error,
         "read-back I/O failure reports an uncertain acknowledgement");
  expect(retried.status == dawn::StoreStatus::unchanged,
         "original CAS request is idempotent after acknowledgement loss");
  expect(backend.write_count == 1,
         "acknowledgement-loss retry does not rewrite flash");
}

void occurrence_journal_commits_without_changing_schedule_revision() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  (void)store.save(make_snapshot(1), 0);
  const auto before = store.load();
  auto occurrence_state = before.snapshot.occurrence_state;
  const dawn::AlarmDefinition due{
      .id = "weekday-wake",
      .schedule_revision = before.snapshot.revision,
      .enabled = true,
      .scheduled_utc_seconds = 1'800'000'000,
  };
  const auto admitted =
      dawn::evaluate_due(due, occurrence_state, 1'800'000'000, 42);

  const auto committed = store.save_occurrence_state(
      occurrence_state, before.snapshot.revision, before.generation);
  const auto after = store.load();

  expect(admitted.status == dawn::EvaluationStatus::ringing &&
             admitted.persist_before_effects,
         "due occurrence requests persistence before alert output");
  expect(committed.status == dawn::StoreStatus::stored &&
             committed.generation == before.generation + 1U,
         "runtime occurrence journal advances the storage generation");
  expect(after.status == dawn::LoadStatus::loaded &&
             after.snapshot.revision == before.snapshot.revision,
         "runtime journal commit preserves the schedule revision");
  expect(after.snapshot.occurrence_state.active &&
             after.snapshot.occurrence_state.active->occurrence_id ==
                 "weekday-wake:1:1800000000",
         "runtime journal commit round-trips the admitted occurrence");
}

void stale_runtime_writer_cannot_overwrite_newer_journal_generation() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  (void)store.save(make_snapshot(1), 0);
  const auto shared = store.load();
  auto first_state = shared.snapshot.occurrence_state;
  const dawn::AlarmDefinition due{
      .id = "weekday-wake",
      .schedule_revision = shared.snapshot.revision,
      .enabled = true,
      .scheduled_utc_seconds = 1'800'000'000,
  };
  (void)dawn::evaluate_due(due, first_state, 1'800'000'000, 42);
  const auto first = store.save_occurrence_state(
      first_state, shared.snapshot.revision, shared.generation);

  auto stale_state = shared.snapshot.occurrence_state;
  stale_state.terminal.push_back(
      {.occurrence_id = "stale:1:1700000000",
       .reason = dawn::TerminalReason::invalid_time});
  const auto stale = store.save_occurrence_state(
      stale_state, shared.snapshot.revision, shared.generation);
  const auto after = store.load();

  expect(first.status == dawn::StoreStatus::stored,
         "first runtime writer commits its occurrence journal");
  expect(stale.status == dawn::StoreStatus::generation_conflict,
         "stale runtime writer gets an explicit generation conflict");
  expect(backend.write_count == 2,
         "generation conflict performs no additional slot write");
  expect(after.snapshot.occurrence_state.active &&
             after.snapshot.occurrence_state.active->occurrence_id ==
                 "weekday-wake:1:1800000000" &&
             after.snapshot.occurrence_state.terminal.empty(),
         "generation conflict preserves the first writer's journal");
}

void schedule_update_preserves_concurrently_committed_occurrence_journal() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  (void)store.save(make_snapshot(1), 0);
  const auto before_due = store.load();
  auto occurrence_state = before_due.snapshot.occurrence_state;
  const dawn::AlarmDefinition due{
      .id = "weekday-wake",
      .schedule_revision = before_due.snapshot.revision,
      .enabled = true,
      .scheduled_utc_seconds = 1'800'000'000,
  };
  (void)dawn::evaluate_due(due, occurrence_state, 1'800'000'000, 42);
  (void)store.save_occurrence_state(
      occurrence_state, before_due.snapshot.revision, before_due.generation);

  auto schedule_update = make_snapshot(2);
  schedule_update.alarms.front().scheduled_utc_seconds = 1'800'086'400;
  const auto updated = store.save(schedule_update, 1);
  const auto after = store.load();

  expect(updated.status == dawn::StoreStatus::stored &&
             after.snapshot.revision == 2,
         "schedule update commits the next user-visible revision");
  expect(after.snapshot.alarms.front().scheduled_utc_seconds == 1'800'086'400,
         "schedule update replaces committed alarm definitions");
  expect(after.snapshot.occurrence_state.active &&
             after.snapshot.occurrence_state.active->occurrence_id ==
                 "weekday-wake:1:1800000000",
         "schedule update carries forward the latest active journal");
}

void runtime_acknowledgement_loss_retry_does_not_rewrite_flash() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  (void)store.save(make_snapshot(1), 0);
  const auto before = store.load();
  auto occurrence_state = before.snapshot.occurrence_state;
  const dawn::AlarmDefinition due{
      .id = "weekday-wake",
      .schedule_revision = before.snapshot.revision,
      .enabled = true,
      .scheduled_utc_seconds = 1'800'000'000,
  };
  (void)dawn::evaluate_due(due, occurrence_state, 1'800'000'000, 42);
  backend.on_write = [&] { backend.fail_next_read = backend.last_written; };

  const auto uncertain = store.save_occurrence_state(
      occurrence_state, before.snapshot.revision, before.generation);
  const auto retried = store.save_occurrence_state(
      occurrence_state, before.snapshot.revision, before.generation);

  expect(uncertain.status == dawn::StoreStatus::io_error,
         "runtime read-back failure reports uncertain acknowledgement");
  expect(retried.status == dawn::StoreStatus::unchanged &&
             retried.generation == before.generation + 1U,
         "identical runtime retry recognizes the committed generation");
  expect(backend.write_count == 2,
         "runtime acknowledgement-loss retry does not rewrite flash");
}

} // namespace

int main() {
  first_commit_round_trips_after_readback_validation();
  newest_corruption_rolls_back_with_visible_diagnostic();
  identical_retry_does_not_consume_another_write();
  legacy_schema_loads_with_explicit_migration_marker();
  legacy_migration_commits_to_opposite_slot_with_rollback();
  oversized_occurrence_state_is_rejected_before_write();
  future_schema_fails_closed_without_reclassification();
  equal_generation_split_brain_fails_closed();
  complete_occurrence_journal_round_trips();
  revision_conflicts_and_skips_fail_before_io();
  torn_write_preserves_last_known_good();
  read_failure_never_becomes_empty_or_last_known_good();
  concurrent_writer_is_rejected_by_backend_transaction();
  generation_header_corruption_cannot_change_slot_selection();
  persisted_write_with_lost_readback_is_idempotent_on_retry();
  occurrence_journal_commits_without_changing_schedule_revision();
  stale_runtime_writer_cannot_overwrite_newer_journal_generation();
  schedule_update_preserves_concurrently_committed_occurrence_journal();
  runtime_acknowledgement_loss_retry_does_not_rewrite_flash();

  if (failures != 0) {
    std::cerr << failures << " assertion(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "schedule_store_tests: PASS\n";
  return EXIT_SUCCESS;
}
