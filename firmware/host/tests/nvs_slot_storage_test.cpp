#include "dawn/nvs_slot_storage.hpp"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <new>
#include <string>
#include <thread>
#include <vector>

namespace {
std::map<std::string, std::vector<std::byte>> blobs;
std::map<std::string, std::vector<std::byte>> pending;
int commits{};
int failures{};
bool fail_set{};
bool fail_commit{};
bool fail_init{};
bool fail_open{};
bool fail_query{};
bool fail_fetch{};
bool wrong_size{};
bool fail_readback{};
bool fail_allocation{};
bool fail_next_allocation{};
int fetches{};
int opens{};
int error_logs{};
void check(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}
} // namespace

// Narrow fault injection: the next allocation after a successful size query.
// All other allocations retain ordinary throwing-new behavior.
void *operator new(std::size_t size) {
  if (fail_next_allocation) {
    fail_next_allocation = false;
    throw std::bad_alloc();
  }
  if (auto *memory = std::malloc(size == 0 ? 1 : size))
    return memory;
  throw std::bad_alloc();
}
void operator delete(void *memory) noexcept { std::free(memory); }
void operator delete(void *memory, std::size_t) noexcept { std::free(memory); }

void dawn_test_log(bool error, const char *, const char *, ...) {
  if (error)
    ++error_logs;
}
extern "C" void app_main();

extern "C" {
esp_err_t nvs_flash_init_partition(const char *partition) {
  check(std::string(partition) == "alarm_nvs", "dedicated partition");
  return fail_init ? ESP_FAIL : ESP_OK;
}
esp_err_t nvs_open_from_partition(const char *partition, const char *name,
                                  nvs_open_mode_t mode, nvs_handle_t *handle) {
  check(std::string(partition) == "alarm_nvs" &&
            std::string(name) == "schedule",
        "fixed partition and namespace");
  check(mode == NVS_READWRITE, "read/write handle");
  ++opens;
  if (fail_open)
    return ESP_FAIL;
  *handle = 1;
  return ESP_OK;
}
void nvs_close(nvs_handle_t) { pending.clear(); }
esp_err_t nvs_get_blob(nvs_handle_t, const char *key, void *out,
                       std::size_t *size) {
  if (fail_query)
    return ESP_FAIL;
  const auto found = blobs.find(key);
  if (found == blobs.end())
    return ESP_ERR_NVS_NOT_FOUND;
  if (!out) {
    *size = found->second.size();
    if (fail_allocation)
      fail_next_allocation = true;
    return ESP_OK;
  }
  ++fetches;
  if (fail_fetch)
    return ESP_FAIL;
  if (*size < found->second.size())
    return ESP_ERR_NVS_INVALID_LENGTH;
  std::memcpy(out, found->second.data(), found->second.size());
  *size = found->second.size();
  if (wrong_size)
    --*size;
  return ESP_OK;
}
esp_err_t nvs_set_blob(nvs_handle_t, const char *key, const void *data,
                       std::size_t size) {
  check(std::string(key) == "slot_a" || std::string(key) == "slot_b",
        "fixed slot key");
  const auto *bytes = static_cast<const std::byte *>(data);
  pending[key] = std::vector<std::byte>(bytes, bytes + size);
  // Model a failed call that nevertheless exposed new bytes. Closing a handle
  // must never be assumed to undo NVS writes.
  if (fail_set) {
    blobs[key] = pending[key];
    return ESP_FAIL;
  }
  return ESP_OK;
}
esp_err_t nvs_commit(nvs_handle_t) {
  ++commits;
  for (const auto &[key, bytes] : pending)
    blobs[key] = bytes;
  pending.clear();
  if (fail_readback)
    fail_fetch = true;
  return fail_commit ? ESP_FAIL : ESP_OK;
}
}

int main(int argc, char **argv) {
  if (argc > 1 && std::string(argv[1]) == "startup") {
    fail_init = true;
    app_main();
    check(error_logs == 1 && opens == 0 && commits == 0,
          "startup reports init failure without opening or writing");
    fail_init = false;
    app_main();
    check(opens == 1 && commits == 0 && blobs.empty(),
          "startup inspects empty storage without provisioning an alarm");
    blobs["slot_a"] = {std::byte{1}};
    app_main();
    check(error_logs == 2 && commits == 0,
          "startup reports corrupt storage as error without repair or erase");
    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  dawn::NvsSlotStorage uninitialized;
  check(!uninitialized.begin_transaction(), "must initialize before opening");
  fail_init = true;
  check(dawn::NvsSlotStorage::initialize() == ESP_FAIL,
        "init error propagated without erase");
  check(!uninitialized.begin_transaction(), "failed init remains unavailable");
  fail_init = false;
  check(dawn::NvsSlotStorage::initialize() == ESP_OK, "initialize");
  dawn::NvsSlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  check(store.load().status == dawn::LoadStatus::empty, "empty partition");
  dawn::ScheduleSnapshot snapshot;
  snapshot.revision = 1;
  snapshot.timezone_rules_version = "2026c";
  check(store.save(snapshot, 0).status == dawn::StoreStatus::stored,
        "save commits record");
  check(commits == 1, "exactly one commit");
  dawn::NvsSlotStorage reopened;
  dawn::AtomicScheduleStore other(reopened);
  const auto loaded = other.load();
  check(loaded.status == dawn::LoadStatus::loaded &&
            loaded.snapshot.revision == 1,
        "reopen loads durable revision");
  check(other.save(snapshot, 0).status == dawn::StoreStatus::unchanged &&
            commits == 1,
        "lost acknowledgement retry does not write");
  if (argc > 1) {
    fail_set = std::string(argv[1]) == "set-failure";
    fail_commit = !fail_set;
    snapshot.revision = 2;
    check(store.save(snapshot, 1).status == dawn::StoreStatus::io_error,
          "write uncertainty is not success");
    fail_set = fail_commit = false;
    check(store.load().status == dawn::LoadStatus::io_error,
          "uncertain bytes cannot become a successful load");
    check(other.load().status == dawn::LoadStatus::io_error,
          "fault latch spans every adapter instance");
    check(dawn::NvsSlotStorage::initialize() == ESP_ERR_INVALID_STATE,
          "reinitialization cannot silently clear uncertainty");
    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  check(backend.read(dawn::StorageSlot::a).status ==
            dawn::SlotReadStatus::io_error,
        "reads require a transaction");
  check(backend.begin_transaction(), "owner acquires transaction");
  const auto opens_before = opens;
  check(!backend.begin_transaction() && !reopened.begin_transaction(),
        "nested begin rejected");
  reopened.end_transaction();
  check(!reopened.begin_transaction(), "wrong instance cannot end transaction");
  std::thread contender([&] {
    check(!backend.begin_transaction() && !reopened.begin_transaction(),
          "other thread excluded");
    backend.end_transaction();
    check(backend.read(dawn::StorageSlot::a).status ==
              dawn::SlotReadStatus::io_error,
          "other thread cannot read through owner");
  });
  contender.join();
  check(opens == opens_before, "rejected ownership touches no NVS handle");
  check(!reopened.begin_transaction(), "other thread cannot release owner");
  check(backend.read(dawn::StorageSlot::a).status ==
            dawn::SlotReadStatus::present,
        "owner remains valid");
  backend.end_transaction();
  backend.end_transaction();
  {
    dawn::NvsSlotStorage temporary;
    check(temporary.begin_transaction(), "temporary acquires");
  }
  check(reopened.begin_transaction(),
        "destructor releases same-thread transaction");
  reopened.end_transaction();

  fail_open = true;
  check(store.load().status == dawn::LoadStatus::io_error,
        "open failure propagates");
  fail_open = false;
  fail_query = true;
  check(store.load().status == dawn::LoadStatus::io_error,
        "query failure is not absence");
  fail_query = false;
  fail_fetch = true;
  check(store.load().status == dawn::LoadStatus::io_error,
        "fetch failure is not absence");
  fail_fetch = false;
  wrong_size = true;
  check(store.load().status == dawn::LoadStatus::io_error,
        "changed size rejected");
  wrong_size = false;
  fail_allocation = true;
  check(store.load().status == dawn::LoadStatus::io_error,
        "allocation failure is contained at the adapter boundary");
  fail_allocation = false;
  check(store.load().status == dawn::LoadStatus::loaded,
        "allocation failure releases the transaction and permits retry");

  const auto saved = blobs;
  blobs["slot_a"] = {};
  check(store.load().status == dawn::LoadStatus::corrupt,
        "zero-length blob is not empty store");
  blobs["slot_a"].resize(dawn::kMaximumStorageRecordBytes + 1);
  const auto fetches_before = fetches;
  check(store.load().status == dawn::LoadStatus::io_error,
        "oversized blob rejected");
  check(fetches == fetches_before,
        "oversize rejected before allocating/fetching payload");
  blobs = saved;
  check(backend.begin_transaction(), "bounds transaction");
  const auto invalid_slot = static_cast<dawn::StorageSlot>(99);
  std::vector<std::byte> too_big(dawn::kMaximumStorageRecordBytes + 1);
  check(!backend.write(dawn::StorageSlot::b, too_big),
        "oversized write rejected");
  check(!backend.write(dawn::StorageSlot::b, {}), "empty write rejected");
  check(!backend.write(invalid_slot, saved.at("slot_a")),
        "invalid slot write rejected");
  check(backend.read(invalid_slot).status == dawn::SlotReadStatus::io_error,
        "invalid slot read rejected");
  too_big.resize(dawn::kMaximumStorageRecordBytes);
  check(backend.write(dawn::StorageSlot::b, too_big),
        "maximum-sized blob admitted");
  check(backend.read(dawn::StorageSlot::b).bytes == too_big,
        "maximum-sized blob roundtrip");
  backend.end_transaction();
  blobs = saved;

  snapshot.revision = 2;
  check(other.save(snapshot, 0).status == dawn::StoreStatus::revision_conflict,
        "stale CAS rejects");
  fail_readback = true;
  check(store.save(snapshot, 1).status == dawn::StoreStatus::io_error,
        "successful commit with failed readback does not acknowledge success");
  fail_readback = fail_fetch = false;
  const auto commits_before = commits;
  check(store.save(snapshot, 1).status == dawn::StoreStatus::unchanged &&
            commits == commits_before,
        "confirmed durable commit can be retried after transient readback "
        "failure");
  blobs["slot_b"].back() ^= std::byte{1};
  const auto rollback = other.load();
  check(rollback.status == dawn::LoadStatus::loaded &&
            rollback.snapshot.revision == 1 && rollback.corruption_detected,
        "CRC corruption falls back to untouched slot");
  blobs["slot_a"].back() ^= std::byte{1};
  check(store.load().status == dawn::LoadStatus::corrupt,
        "both corrupt fail closed");
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
