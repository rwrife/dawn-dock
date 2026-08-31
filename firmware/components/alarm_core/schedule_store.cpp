#include "dawn/schedule_store.hpp"

#include <algorithm>
#include <array>
#include <bit>
#include <limits>
#include <optional>
#include <string_view>
#include <type_traits>
#include <unordered_set>
#include <utility>

namespace dawn {
namespace {

constexpr std::array<std::byte, 4> kMagic{std::byte{'D'}, std::byte{'D'},
                                          std::byte{'S'}, std::byte{'T'}};
constexpr std::size_t kHeaderSize = 24;

class Writer {
public:
  template <typename T> void integer(T value) {
    using Unsigned = std::make_unsigned_t<T>;
    const auto encoded = std::bit_cast<Unsigned>(value);
    for (std::size_t byte = 0; byte < sizeof(T); ++byte) {
      bytes_.push_back(
          static_cast<std::byte>((encoded >> (byte * 8U)) & 0xffU));
    }
  }

  bool string(std::string_view value) {
    if (value.size() > std::numeric_limits<std::uint16_t>::max()) {
      return false;
    }
    integer<std::uint16_t>(static_cast<std::uint16_t>(value.size()));
    for (const char character : value) {
      bytes_.push_back(static_cast<std::byte>(character));
    }
    return true;
  }

  void append(std::span<const std::byte> bytes) {
    bytes_.insert(bytes_.end(), bytes.begin(), bytes.end());
  }

  [[nodiscard]] const std::vector<std::byte> &bytes() const { return bytes_; }
  [[nodiscard]] std::vector<std::byte> take() { return std::move(bytes_); }

private:
  std::vector<std::byte> bytes_;
};

class Reader {
public:
  explicit Reader(std::span<const std::byte> bytes) : bytes_(bytes) {}

  template <typename T> bool integer(T &value) {
    if (remaining() < sizeof(T)) {
      return false;
    }
    using Unsigned = std::make_unsigned_t<T>;
    Unsigned decoded{};
    for (std::size_t byte = 0; byte < sizeof(T); ++byte) {
      decoded |= static_cast<Unsigned>(
                     std::to_integer<unsigned int>(bytes_[offset_ + byte]))
                 << (byte * 8U);
    }
    value = std::bit_cast<T>(decoded);
    offset_ += sizeof(T);
    return true;
  }

  bool string(std::string &value) {
    std::uint16_t length{};
    if (!integer(length) || remaining() < length) {
      return false;
    }
    value.clear();
    value.reserve(length);
    for (std::size_t index = 0; index < length; ++index) {
      value.push_back(static_cast<char>(
          std::to_integer<unsigned char>(bytes_[offset_ + index])));
    }
    offset_ += length;
    return true;
  }

  [[nodiscard]] std::size_t remaining() const {
    return bytes_.size() - offset_;
  }

private:
  std::span<const std::byte> bytes_;
  std::size_t offset_{};
};

std::uint32_t update_crc32(std::uint32_t crc,
                           std::span<const std::byte> bytes) {
  for (const auto byte : bytes) {
    crc ^= std::to_integer<std::uint8_t>(byte);
    for (int bit = 0; bit < 8; ++bit) {
      const auto mask =
          static_cast<std::uint32_t>(-static_cast<std::int32_t>(crc & 1U));
      crc = (crc >> 1U) ^ (0xedb88320U & mask);
    }
  }
  return crc;
}

std::uint32_t crc32(std::span<const std::byte> bytes) {
  return ~update_crc32(0xffffffffU, bytes);
}

std::uint32_t current_record_crc(std::span<const std::byte> bytes) {
  constexpr std::size_t protected_header_offset = kMagic.size();
  constexpr std::size_t protected_header_size = 16;
  auto crc = update_crc32(0xffffffffU, bytes.subspan(protected_header_offset,
                                                     protected_header_size));
  crc = update_crc32(crc, bytes.subspan(kHeaderSize));
  return ~crc;
}

bool valid_string(std::string_view value, std::size_t maximum) {
  return !value.empty() && value.size() <= maximum &&
         std::none_of(value.begin(), value.end(), [](char character) {
           const auto byte = static_cast<unsigned char>(character);
           return byte == 0U || byte < 0x20U;
         });
}

bool valid_optional_string(std::string_view value, std::size_t maximum) {
  return value.empty() || valid_string(value, maximum);
}

bool validate_snapshot(const ScheduleSnapshot &snapshot) {
  if (snapshot.revision == 0 ||
      !valid_string(snapshot.timezone_rules_version,
                    kMaximumTimezoneVersionBytes) ||
      snapshot.alarms.size() > kMaximumStoredAlarms ||
      snapshot.occurrence_state.terminal.size() > kRecentTerminalRetention ||
      snapshot.occurrence_state.terminal_high_watermarks.size() >
          kTerminalHighWatermarkCapacity) {
    return false;
  }

  std::unordered_set<std::string> alarm_ids;
  for (const auto &alarm : snapshot.alarms) {
    if (!valid_string(alarm.id, kMaximumAlarmIdBytes) ||
        alarm.schedule_revision == 0 ||
        alarm.schedule_revision > snapshot.revision ||
        !alarm_ids.insert(alarm.id).second) {
      return false;
    }
  }

  const auto &occurrence_state = snapshot.occurrence_state;
  if (occurrence_state.active) {
    const auto &active = *occurrence_state.active;
    if (!valid_string(active.alarm_id, kMaximumAlarmIdBytes) ||
        !valid_string(active.occurrence_id, kMaximumOccurrenceIdBytes) ||
        !valid_optional_string(active.last_recovery_boot_id,
                               kMaximumBootIdBytes) ||
        active.snooze_count > kMaximumSnoozes ||
        (active.snooze_deadline_monotonic_seconds &&
         *active.snooze_deadline_monotonic_seconds <
             active.first_ring_monotonic_seconds)) {
      return false;
    }
  }

  std::unordered_set<std::string> terminal_ids;
  for (const auto &terminal : occurrence_state.terminal) {
    if (!valid_string(terminal.occurrence_id, kMaximumOccurrenceIdBytes) ||
        terminal.reason > TerminalReason::prolonged_power_off ||
        !terminal_ids.insert(terminal.occurrence_id).second ||
        (occurrence_state.active &&
         occurrence_state.active->occurrence_id == terminal.occurrence_id)) {
      return false;
    }
  }

  std::unordered_set<std::string> watermark_ids;
  for (const auto &watermark : occurrence_state.terminal_high_watermarks) {
    if (!valid_string(watermark.alarm_id, kMaximumAlarmIdBytes) ||
        !watermark_ids.insert(watermark.alarm_id).second) {
      return false;
    }
  }
  return true;
}

bool write_occurrence_state(Writer &writer, const PersistentAlarmState &state) {
  writer.integer<std::uint8_t>(state.active.has_value() ? 1U : 0U);
  if (state.active) {
    const auto &active = *state.active;
    if (!writer.string(active.alarm_id) ||
        !writer.string(active.occurrence_id)) {
      return false;
    }
    writer.integer(active.scheduled_utc_seconds);
    writer.integer(active.first_ring_utc_seconds);
    writer.integer(active.first_ring_monotonic_seconds);
    writer.integer<std::uint8_t>(
        active.snooze_deadline_monotonic_seconds.has_value() ? 1U : 0U);
    if (active.snooze_deadline_monotonic_seconds) {
      writer.integer(*active.snooze_deadline_monotonic_seconds);
    }
    writer.integer(active.snooze_count);
    writer.integer<std::uint8_t>(active.recovered_after_reboot ? 1U : 0U);
    if (!writer.string(active.last_recovery_boot_id)) {
      return false;
    }
  }

  writer.integer<std::uint16_t>(
      static_cast<std::uint16_t>(state.terminal.size()));
  for (const auto &terminal : state.terminal) {
    if (!writer.string(terminal.occurrence_id)) {
      return false;
    }
    writer.integer<std::uint8_t>(static_cast<std::uint8_t>(terminal.reason));
  }

  writer.integer<std::uint16_t>(
      static_cast<std::uint16_t>(state.terminal_high_watermarks.size()));
  for (const auto &watermark : state.terminal_high_watermarks) {
    if (!writer.string(watermark.alarm_id)) {
      return false;
    }
    writer.integer(watermark.scheduled_utc_seconds);
  }
  return true;
}

bool read_boolean(Reader &reader, bool &value) {
  std::uint8_t encoded{};
  if (!reader.integer(encoded) || encoded > 1U) {
    return false;
  }
  value = encoded == 1U;
  return true;
}

bool read_occurrence_state(Reader &reader, PersistentAlarmState &state) {
  bool has_active{};
  if (!read_boolean(reader, has_active)) {
    return false;
  }
  if (has_active) {
    ActiveOccurrence active;
    if (!reader.string(active.alarm_id) ||
        !reader.string(active.occurrence_id) ||
        !reader.integer(active.scheduled_utc_seconds) ||
        !reader.integer(active.first_ring_utc_seconds) ||
        !reader.integer(active.first_ring_monotonic_seconds)) {
      return false;
    }
    bool has_deadline{};
    if (!read_boolean(reader, has_deadline)) {
      return false;
    }
    if (has_deadline) {
      std::int64_t deadline{};
      if (!reader.integer(deadline)) {
        return false;
      }
      active.snooze_deadline_monotonic_seconds = deadline;
    }
    if (!reader.integer(active.snooze_count) ||
        !read_boolean(reader, active.recovered_after_reboot) ||
        !reader.string(active.last_recovery_boot_id)) {
      return false;
    }
    state.active = std::move(active);
  }

  std::uint16_t terminal_count{};
  if (!reader.integer(terminal_count) ||
      terminal_count > kRecentTerminalRetention) {
    return false;
  }
  state.terminal.reserve(terminal_count);
  for (std::uint16_t index = 0; index < terminal_count; ++index) {
    TerminalOccurrence terminal;
    std::uint8_t reason{};
    if (!reader.string(terminal.occurrence_id) || !reader.integer(reason) ||
        reason >
            static_cast<std::uint8_t>(TerminalReason::prolonged_power_off)) {
      return false;
    }
    terminal.reason = static_cast<TerminalReason>(reason);
    state.terminal.push_back(std::move(terminal));
  }

  std::uint16_t watermark_count{};
  if (!reader.integer(watermark_count) ||
      watermark_count > kTerminalHighWatermarkCapacity) {
    return false;
  }
  state.terminal_high_watermarks.reserve(watermark_count);
  for (std::uint16_t index = 0; index < watermark_count; ++index) {
    TerminalHighWatermark watermark;
    if (!reader.string(watermark.alarm_id) ||
        !reader.integer(watermark.scheduled_utc_seconds)) {
      return false;
    }
    state.terminal_high_watermarks.push_back(std::move(watermark));
  }
  return true;
}

std::optional<std::vector<std::byte>>
encode_record(const ScheduleSnapshot &snapshot, std::uint64_t generation) {
  if (!validate_snapshot(snapshot)) {
    return std::nullopt;
  }

  Writer payload;
  payload.integer(snapshot.revision);
  if (!payload.string(snapshot.timezone_rules_version)) {
    return std::nullopt;
  }
  payload.integer<std::uint16_t>(
      static_cast<std::uint16_t>(snapshot.alarms.size()));
  for (const auto &alarm : snapshot.alarms) {
    if (!payload.string(alarm.id)) {
      return std::nullopt;
    }
    payload.integer(alarm.schedule_revision);
    payload.integer<std::uint8_t>(alarm.enabled ? 1U : 0U);
    payload.integer(alarm.scheduled_utc_seconds);
  }
  if (!write_occurrence_state(payload, snapshot.occurrence_state) ||
      payload.bytes().size() + kHeaderSize > kMaximumStorageRecordBytes) {
    return std::nullopt;
  }

  Writer integrity;
  integrity.integer<std::uint16_t>(kCurrentStorageSchemaVersion);
  integrity.integer<std::uint16_t>(0);
  integrity.integer(generation);
  integrity.integer<std::uint32_t>(
      static_cast<std::uint32_t>(payload.bytes().size()));
  integrity.append(payload.bytes());

  Writer record;
  record.append(kMagic);
  record.integer<std::uint16_t>(kCurrentStorageSchemaVersion);
  record.integer<std::uint16_t>(0);
  record.integer(generation);
  record.integer<std::uint32_t>(
      static_cast<std::uint32_t>(payload.bytes().size()));
  record.integer(crc32(integrity.bytes()));
  record.append(payload.bytes());
  return record.take();
}

struct DecodedRecord {
  ScheduleSnapshot snapshot;
  std::uint64_t generation{};
  bool migrated{};
};

std::optional<DecodedRecord> decode_record(std::span<const std::byte> bytes) {
  if (bytes.size() < kHeaderSize || bytes.size() > kMaximumStorageRecordBytes ||
      !std::equal(kMagic.begin(), kMagic.end(), bytes.begin())) {
    return std::nullopt;
  }

  Reader header(bytes.subspan(kMagic.size()));
  std::uint16_t schema{};
  std::uint16_t reserved{};
  std::uint64_t generation{};
  std::uint32_t payload_size{};
  std::uint32_t expected_crc{};
  if (!header.integer(schema) || !header.integer(reserved) ||
      !header.integer(generation) || !header.integer(payload_size) ||
      !header.integer(expected_crc) || reserved != 0 || generation == 0 ||
      (schema != 1U && schema != kCurrentStorageSchemaVersion) ||
      payload_size != bytes.size() - kHeaderSize) {
    return std::nullopt;
  }

  const auto payload = bytes.subspan(kHeaderSize);
  const auto actual_crc =
      schema == 1U ? crc32(payload) : current_record_crc(bytes);
  if (actual_crc != expected_crc) {
    return std::nullopt;
  }

  Reader reader(payload);
  ScheduleSnapshot snapshot;
  std::uint16_t alarm_count{};
  if (!reader.integer(snapshot.revision)) {
    return std::nullopt;
  }
  if (schema == kCurrentStorageSchemaVersion) {
    if (!reader.string(snapshot.timezone_rules_version)) {
      return std::nullopt;
    }
  } else {
    snapshot.timezone_rules_version = "legacy-v1-unpinned";
  }
  if (!reader.integer(alarm_count) || alarm_count > kMaximumStoredAlarms) {
    return std::nullopt;
  }
  snapshot.alarms.reserve(alarm_count);
  for (std::uint16_t index = 0; index < alarm_count; ++index) {
    StoredAlarmDefinition alarm;
    if (!reader.string(alarm.id) || !reader.integer(alarm.schedule_revision) ||
        !read_boolean(reader, alarm.enabled) ||
        !reader.integer(alarm.scheduled_utc_seconds)) {
      return std::nullopt;
    }
    snapshot.alarms.push_back(std::move(alarm));
  }
  if (!read_occurrence_state(reader, snapshot.occurrence_state) ||
      reader.remaining() != 0 || !validate_snapshot(snapshot)) {
    return std::nullopt;
  }
  return DecodedRecord{std::move(snapshot), generation,
                       schema != kCurrentStorageSchemaVersion};
}

std::optional<std::uint64_t>
intact_future_schema_generation(std::span<const std::byte> bytes) {
  if (bytes.size() < kHeaderSize || bytes.size() > kMaximumStorageRecordBytes ||
      !std::equal(kMagic.begin(), kMagic.end(), bytes.begin())) {
    return std::nullopt;
  }
  Reader header(bytes.subspan(kMagic.size()));
  std::uint16_t schema{};
  std::uint16_t reserved{};
  std::uint64_t generation{};
  std::uint32_t payload_size{};
  std::uint32_t expected_crc{};
  if (!header.integer(schema) || !header.integer(reserved) ||
      !header.integer(generation) || !header.integer(payload_size) ||
      !header.integer(expected_crc) || reserved != 0 || generation == 0 ||
      schema <= kCurrentStorageSchemaVersion ||
      payload_size != bytes.size() - kHeaderSize ||
      current_record_crc(bytes) != expected_crc) {
    return std::nullopt;
  }
  return generation;
}

bool active_equal(const std::optional<ActiveOccurrence> &left,
                  const std::optional<ActiveOccurrence> &right) {
  if (left.has_value() != right.has_value()) {
    return false;
  }
  if (!left) {
    return true;
  }
  return left->alarm_id == right->alarm_id &&
         left->occurrence_id == right->occurrence_id &&
         left->scheduled_utc_seconds == right->scheduled_utc_seconds &&
         left->first_ring_utc_seconds == right->first_ring_utc_seconds &&
         left->first_ring_monotonic_seconds ==
             right->first_ring_monotonic_seconds &&
         left->snooze_deadline_monotonic_seconds ==
             right->snooze_deadline_monotonic_seconds &&
         left->snooze_count == right->snooze_count &&
         left->recovered_after_reboot == right->recovered_after_reboot &&
         left->last_recovery_boot_id == right->last_recovery_boot_id;
}

bool terminal_equal(const std::vector<TerminalOccurrence> &left,
                    const std::vector<TerminalOccurrence> &right) {
  return left.size() == right.size() &&
         std::equal(
             left.begin(), left.end(), right.begin(),
             [](const TerminalOccurrence &lhs, const TerminalOccurrence &rhs) {
               return lhs.occurrence_id == rhs.occurrence_id &&
                      lhs.reason == rhs.reason;
             });
}

bool watermarks_equal(const std::vector<TerminalHighWatermark> &left,
                      const std::vector<TerminalHighWatermark> &right) {
  return left.size() == right.size() &&
         std::equal(left.begin(), left.end(), right.begin(),
                    [](const TerminalHighWatermark &lhs,
                       const TerminalHighWatermark &rhs) {
                      return lhs.alarm_id == rhs.alarm_id &&
                             lhs.scheduled_utc_seconds ==
                                 rhs.scheduled_utc_seconds;
                    });
}

bool snapshots_equal(const ScheduleSnapshot &left,
                     const ScheduleSnapshot &right) {
  return left.revision == right.revision &&
         left.timezone_rules_version == right.timezone_rules_version &&
         left.alarms == right.alarms &&
         active_equal(left.occurrence_state.active,
                      right.occurrence_state.active) &&
         terminal_equal(left.occurrence_state.terminal,
                        right.occurrence_state.terminal) &&
         watermarks_equal(left.occurrence_state.terminal_high_watermarks,
                          right.occurrence_state.terminal_high_watermarks);
}

StorageSlot opposite(StorageSlot slot) {
  return slot == StorageSlot::a ? StorageSlot::b : StorageSlot::a;
}

class StorageTransaction {
public:
  explicit StorageTransaction(SlotStorage &storage)
      : storage_(storage), active_(storage_.begin_transaction()) {}

  StorageTransaction(const StorageTransaction &) = delete;
  StorageTransaction &operator=(const StorageTransaction &) = delete;

  ~StorageTransaction() {
    if (active_) {
      storage_.end_transaction();
    }
  }

  [[nodiscard]] bool active() const { return active_; }

private:
  SlotStorage &storage_;
  bool active_{};
};

} // namespace

LoadResult AtomicScheduleStore::load() const {
  StorageTransaction transaction(storage_);
  if (!transaction.active()) {
    LoadResult result;
    result.status = LoadStatus::io_error;
    return result;
  }
  return load_unlocked();
}

LoadResult AtomicScheduleStore::load_unlocked() const {
  LoadResult result;
  bool any_present = false;
  bool invalid_present = false;
  bool ambiguous = false;
  std::optional<std::uint64_t> future_generation;
  for (const auto slot : {StorageSlot::a, StorageSlot::b}) {
    const auto read_result = storage_.read(slot);
    if (read_result.status == SlotReadStatus::io_error) {
      result = {};
      result.status = LoadStatus::io_error;
      return result;
    }
    if (read_result.status == SlotReadStatus::empty) {
      continue;
    }
    any_present = true;
    const auto &bytes = read_result.bytes;
    const auto unsupported = intact_future_schema_generation(bytes);
    if (unsupported) {
      if (!future_generation || *unsupported > *future_generation) {
        future_generation = *unsupported;
      }
      continue;
    }
    const auto decoded = decode_record(bytes);
    if (!decoded) {
      invalid_present = true;
      continue;
    }
    if (result.status == LoadStatus::loaded &&
        decoded->generation == result.generation &&
        (decoded->migrated != result.migrated ||
         !snapshots_equal(decoded->snapshot, result.snapshot))) {
      ambiguous = true;
      continue;
    }
    if (result.status != LoadStatus::loaded ||
        decoded->generation > result.generation) {
      result.status = LoadStatus::loaded;
      result.snapshot = decoded->snapshot;
      result.generation = decoded->generation;
      result.source = slot;
      result.migrated = decoded->migrated;
      ambiguous = false;
    }
  }
  if (future_generation && (result.status != LoadStatus::loaded ||
                            *future_generation >= result.generation)) {
    result = {};
    result.status = LoadStatus::unsupported_schema;
    result.generation = *future_generation;
  } else if (ambiguous) {
    result.status = LoadStatus::ambiguous;
  } else if (result.status == LoadStatus::loaded) {
    result.corruption_detected = invalid_present;
  } else if (any_present) {
    result.status = LoadStatus::corrupt;
  }
  return result;
}

StoreResult AtomicScheduleStore::migrate_to_current_schema() {
  StorageTransaction transaction(storage_);
  if (!transaction.active()) {
    return {.status = StoreStatus::io_error};
  }
  const auto current = load_unlocked();
  if (current.status == LoadStatus::io_error) {
    return {.status = StoreStatus::io_error};
  }
  if (current.status == LoadStatus::corrupt ||
      current.status == LoadStatus::unsupported_schema ||
      current.status == LoadStatus::ambiguous) {
    return {.status = StoreStatus::corrupt_store};
  }
  if (current.status == LoadStatus::empty || !current.migrated) {
    return {.status = StoreStatus::unchanged,
            .generation = current.generation,
            .destination = current.source};
  }
  if (current.generation == std::numeric_limits<std::uint64_t>::max()) {
    return {.status = StoreStatus::invalid_snapshot,
            .generation = current.generation,
            .destination = current.source};
  }

  const auto generation = current.generation + 1U;
  const auto destination = opposite(current.source);
  const auto encoded = encode_record(current.snapshot, generation);
  if (!encoded) {
    return {.status = StoreStatus::invalid_snapshot,
            .generation = current.generation,
            .destination = destination};
  }
  if (!storage_.write(destination, *encoded)) {
    return {.status = StoreStatus::io_error,
            .generation = current.generation,
            .destination = destination};
  }

  const auto written = storage_.read(destination);
  if (written.status == SlotReadStatus::io_error) {
    return {.status = StoreStatus::io_error,
            .generation = current.generation,
            .destination = destination};
  }
  const auto verified = written.status == SlotReadStatus::present
                            ? decode_record(written.bytes)
                            : std::nullopt;
  if (!verified || verified->migrated || verified->generation != generation ||
      !snapshots_equal(verified->snapshot, current.snapshot)) {
    return {.status = StoreStatus::verification_failed,
            .generation = current.generation,
            .destination = destination};
  }
  return {.status = StoreStatus::stored,
          .generation = generation,
          .destination = destination};
}

StoreResult AtomicScheduleStore::save(const ScheduleSnapshot &snapshot,
                                      std::uint64_t expected_revision) {
  StorageTransaction transaction(storage_);
  if (!transaction.active()) {
    return {.status = StoreStatus::io_error};
  }
  const auto current = load_unlocked();
  if (current.status == LoadStatus::io_error) {
    return {.status = StoreStatus::io_error};
  }
  if (current.status == LoadStatus::corrupt ||
      current.status == LoadStatus::unsupported_schema ||
      current.status == LoadStatus::ambiguous) {
    return {.status = StoreStatus::corrupt_store};
  }
  const auto current_revision =
      current.status == LoadStatus::loaded ? current.snapshot.revision : 0;
  auto committed_snapshot = snapshot;
  if (current.status == LoadStatus::loaded) {
    committed_snapshot.occurrence_state = current.snapshot.occurrence_state;
  }
  const bool acknowledgement_loss_retry =
      expected_revision != std::numeric_limits<std::uint64_t>::max() &&
      expected_revision + 1U == current_revision;
  if (current.status == LoadStatus::loaded &&
      snapshots_equal(current.snapshot, committed_snapshot) &&
      (expected_revision == current_revision || acknowledgement_loss_retry)) {
    return {.status = StoreStatus::unchanged,
            .generation = current.generation,
            .destination = current.source};
  }
  if (current_revision != expected_revision) {
    return {.status = StoreStatus::revision_conflict,
            .generation = current.generation};
  }
  if (committed_snapshot.revision != expected_revision + 1U ||
      !validate_snapshot(committed_snapshot)) {
    return {.status = StoreStatus::invalid_snapshot,
            .generation = current.generation};
  }

  const auto generation = current.generation + 1U;
  if (generation == 0) {
    return {.status = StoreStatus::invalid_snapshot,
            .generation = current.generation};
  }
  const auto destination = current.status == LoadStatus::loaded
                               ? opposite(current.source)
                               : StorageSlot::a;
  const auto encoded = encode_record(committed_snapshot, generation);
  if (!encoded) {
    return {.status = StoreStatus::invalid_snapshot,
            .generation = current.generation,
            .destination = destination};
  }
  if (!storage_.write(destination, *encoded)) {
    return {.status = StoreStatus::io_error,
            .generation = current.generation,
            .destination = destination};
  }

  const auto written = storage_.read(destination);
  if (written.status == SlotReadStatus::io_error) {
    return {.status = StoreStatus::io_error,
            .generation = current.generation,
            .destination = destination};
  }
  const auto verified = written.status == SlotReadStatus::present
                            ? decode_record(written.bytes)
                            : std::nullopt;
  if (!verified || verified->generation != generation ||
      !snapshots_equal(verified->snapshot, committed_snapshot)) {
    return {.status = StoreStatus::verification_failed,
            .generation = current.generation,
            .destination = destination};
  }
  return {.status = StoreStatus::stored,
          .generation = generation,
          .destination = destination};
}

StoreResult AtomicScheduleStore::save_occurrence_state(
    const PersistentAlarmState &occurrence_state,
    std::uint64_t expected_revision, std::uint64_t expected_generation) {
  StorageTransaction transaction(storage_);
  if (!transaction.active()) {
    return {.status = StoreStatus::io_error};
  }
  const auto current = load_unlocked();
  if (current.status == LoadStatus::io_error) {
    return {.status = StoreStatus::io_error};
  }
  if (current.status == LoadStatus::corrupt ||
      current.status == LoadStatus::unsupported_schema ||
      current.status == LoadStatus::ambiguous) {
    return {.status = StoreStatus::corrupt_store};
  }
  if (current.status != LoadStatus::loaded ||
      current.snapshot.revision != expected_revision) {
    return {.status = StoreStatus::revision_conflict,
            .generation = current.generation,
            .destination = current.source};
  }
  auto updated = current.snapshot;
  updated.occurrence_state = occurrence_state;
  if (!validate_snapshot(updated)) {
    return {.status = StoreStatus::invalid_snapshot,
            .generation = current.generation,
            .destination = current.source};
  }
  const bool acknowledgement_loss_retry =
      expected_generation != std::numeric_limits<std::uint64_t>::max() &&
      expected_generation + 1U == current.generation;
  if (snapshots_equal(updated, current.snapshot) &&
      (current.generation == expected_generation ||
       acknowledgement_loss_retry)) {
    return {.status = StoreStatus::unchanged,
            .generation = current.generation,
            .destination = current.source};
  }
  if (current.generation != expected_generation) {
    return {.status = StoreStatus::generation_conflict,
            .generation = current.generation,
            .destination = current.source};
  }
  if (current.generation == std::numeric_limits<std::uint64_t>::max()) {
    return {.status = StoreStatus::invalid_snapshot,
            .generation = current.generation,
            .destination = current.source};
  }

  const auto generation = current.generation + 1U;
  const auto destination = opposite(current.source);
  const auto encoded = encode_record(updated, generation);
  if (!encoded) {
    return {.status = StoreStatus::invalid_snapshot,
            .generation = current.generation,
            .destination = destination};
  }
  if (!storage_.write(destination, *encoded)) {
    return {.status = StoreStatus::io_error,
            .generation = current.generation,
            .destination = destination};
  }

  const auto written = storage_.read(destination);
  if (written.status == SlotReadStatus::io_error) {
    return {.status = StoreStatus::io_error,
            .generation = current.generation,
            .destination = destination};
  }
  const auto verified = written.status == SlotReadStatus::present
                            ? decode_record(written.bytes)
                            : std::nullopt;
  if (!verified || verified->generation != generation ||
      !snapshots_equal(verified->snapshot, updated)) {
    return {.status = StoreStatus::verification_failed,
            .generation = current.generation,
            .destination = destination};
  }
  return {.status = StoreStatus::stored,
          .generation = generation,
          .destination = destination};
}

} // namespace dawn
