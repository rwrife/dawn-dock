#pragma once

#include "dawn/alarm_engine.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace dawn {

constexpr std::uint16_t kCurrentStorageSchemaVersion = 2;
constexpr std::size_t kMaximumStoredAlarms = 32;
constexpr std::size_t kMaximumAlarmIdBytes = 64;
constexpr std::size_t kMaximumOccurrenceIdBytes = 160;
constexpr std::size_t kMaximumBootIdBytes = 64;
constexpr std::size_t kMaximumTimezoneVersionBytes = 64;
constexpr std::size_t kMaximumStorageRecordBytes = 64 * 1024;

struct StoredAlarmDefinition {
  std::string id;
  std::uint64_t schedule_revision{};
  bool enabled{};
  std::int64_t scheduled_utc_seconds{};

  bool operator==(const StoredAlarmDefinition &) const = default;
};

struct ScheduleSnapshot {
  std::uint64_t revision{};
  std::string timezone_rules_version;
  std::vector<StoredAlarmDefinition> alarms;
  PersistentAlarmState occurrence_state;
};

enum class StorageSlot { a, b };

enum class SlotReadStatus { empty, present, io_error };

struct SlotReadResult {
  SlotReadStatus status{SlotReadStatus::empty};
  std::vector<std::byte> bytes;
};

class SlotStorage {
public:
  virtual ~SlotStorage() = default;

  // The transaction is exclusive across every store instance sharing this
  // backend. It spans both-slot reads, one per-slot atomic replacement, and
  // read-back verification. Implementations must distinguish absence from I/O
  // failure and must not expose a partial record as a successful read.
  virtual bool begin_transaction() = 0;
  virtual void end_transaction() = 0;
  [[nodiscard]] virtual SlotReadResult read(StorageSlot slot) const = 0;
  virtual bool write(StorageSlot slot, std::span<const std::byte> bytes) = 0;
};

enum class LoadStatus {
  empty,
  loaded,
  corrupt,
  unsupported_schema,
  ambiguous,
  io_error,
};

enum class StoreStatus {
  stored,
  unchanged,
  revision_conflict,
  invalid_snapshot,
  corrupt_store,
  io_error,
  verification_failed,
};

struct LoadResult {
  LoadStatus status{LoadStatus::empty};
  ScheduleSnapshot snapshot;
  std::uint64_t generation{};
  StorageSlot source{StorageSlot::a};
  bool migrated{};
  bool corruption_detected{};
};

struct StoreResult {
  StoreStatus status{StoreStatus::io_error};
  std::uint64_t generation{};
  StorageSlot destination{StorageSlot::a};
};

class AtomicScheduleStore {
public:
  explicit AtomicScheduleStore(SlotStorage &storage) : storage_(storage) {}

  [[nodiscard]] LoadResult load() const;
  [[nodiscard]] StoreResult migrate_to_current_schema();
  [[nodiscard]] StoreResult save(const ScheduleSnapshot &snapshot,
                                 std::uint64_t expected_revision);

private:
  [[nodiscard]] LoadResult load_unlocked() const;

  SlotStorage &storage_;
};

} // namespace dawn
