# ESP-IDF NVS schedule binding

Issue #31, parent #5. **Software evidence only; not flashed or bench-tested.**

## Contract and implementation

`components/nvs_storage` is configured to build against ESP-IDF v5.5.5 NVS.
Compatibility must pass the real target cross-build, not only fake headers.
`NvsSlotStorage` fixes the partition to `alarm_nvs`, namespace to `schedule`,
and keys to `slot_a` / `slot_b`. The existing `AtomicScheduleStore` owns record
encoding, CRC, generation/revision selection, migration, rollback, CAS, and
read-back verification. The adapter stores one complete record per blob and
calls `nvs_commit` after every successful `nvs_set_blob`.

A process-wide recursive mutex is retained from `begin_transaction` through
`end_transaction`, covering both reads, CAS, write, commit, and read-back across
all adapter instances. Contention/nested begin fails immediately rather than
waiting for another task. Methods check instance and thread ownership under the
same mutex; wrong-owner reads/writes/end cannot disturb the active transaction.
Use from task context, not ISRs. Begin/end and destruction of an active instance
must occur on the same task; lifetime must outlive all users. No other code may
open these keys directly. This does not bound the latency of NVS flash operations.

Reads distinguish missing keys from errors. Size is queried first and capped at
64 KiB before allocation; the second read must return exactly that size. Zero
bytes is a present malformed record, not an absent schedule. Unknown keys/types,
read errors, oversize, and size changes fail closed. Empty and oversized writes
are rejected before touching NVS.

The buffer allocation catches `std::bad_alloc` and returns `io_error`; host
fault injection exercises this path and retry after releasing the transaction.
The target now enables C++ exceptions to support this narrow allocation guard.
The pure parser still uses explicit error returns rather than exceptions.
This is not a claim that every allocation elsewhere in the firmware is guarded;
whole-system OOM containment and the exception-runtime memory budget remain
target integration work.

**A failed set or commit can have changed flash/cache.** `nvs_close` is not a
rollback guarantee. Any such error latches the entire adapter partition
unavailable until reboot, including reads and other adapter instances. Calling
`initialize` again cannot clear the latch. The application must expose a storage
fault and suppress new effects, not automatically reboot/erase in a loop. On a
subsequent boot, NVS recovery and the codec re-evaluate the durable records; the
new or old generation may survive. That is not a claim that an unacknowledged
write was rolled back. Successful commit followed by a transient read-back error
also returns failure; a later fully validated read can support the core's
no-write acknowledgement retry.

Initialization calls only `nvs_flash_init_partition`; it never calls an erase
function on full pages, version mismatch, or any other error. `app_main` now
initializes and inspects storage, logs status/revision/rollback (no schedule
payload), and returns. It does not install a demo alarm or start the runtime.
NVS initialization/open can create internal metadata; startup is read-only with
respect to alarm records, not a claim of zero flash activity.

## Partition budget and upgrade boundary

`firmware/partitions.csv` fits the conservative 2 MiB build layout:

| Region | Offset | Size |
|---|---:|---:|
| default NVS (reserved for other services) | `0x9000` | `0x6000` |
| PHY | `0xf000` | `0x1000` |
| alarm NVS | `0x10000` | `0x40000` (256 KiB) |
| factory app | `0x50000` | `0x1b0000` |

The nominal payload budget is two 64 KiB records and a third replacement copy
(192 KiB). The remaining 64 KiB must cover **all** page headers, blob/chunk
indexes, namespace entries, and garbage-collection/free-page requirements;
it is not 64 KiB of usable spare payload. Effective spare capacity is smaller
and has not been measured. This is a conservative allocation proposal, not a
tested maximum-size replacement, fragmentation, or endurance guarantee. Writes occur only on
actual core state changes; identical acknowledgement retries remain write-free.
No OTA slot or authenticated update path is introduced.

**This changes the former factory application offset.** Do not flash only the
application at the old offset. Use a complete matching build/partition table and
archive/export any valuable existing data before changing layouts. There is no
physical-layout migration tool or tested device backup/restore path yet. The
core's schema-v1-to-v2 record migration is a different concern and must not be
represented as a partition-layout migration. Do not erase an existing user's
data automatically. First-device setup and upgrade/recovery remain bench gates.

## API evidence

Ground truth: Espressif's pinned
[`nvs.h` at v5.5.5](https://github.com/espressif/esp-idf/blob/v5.5.5/components/nvs_flash/include/nvs.h)
(`nvs_open_from_partition`, `nvs_get_blob`, `nvs_set_blob`, `nvs_commit`,
`nvs_close`) and
[NVS documentation](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/api-reference/storage/nvs_flash.html).
The API documents query-then-fetch buffer sizing and explicit commit; closing
a handle does not promise to commit. The adapter does not infer durability from
a close or from the host fake.

## Reproducible checks and limits

```bash
cmake -S firmware/host -B /tmp/dawn-31-host
cmake --build /tmp/dawn-31-host --parallel
ctest --test-dir /tmp/dawn-31-host --output-on-failure
python3 scripts/check_docs.py
python3 scripts/check_component_selection.py
```

Run the Python checks after staging; they inspect indexed sources. The host
suite includes the actual adapter and `app_main` compiled with test-only NVS/log
headers. The fake models explicit commits and deliberately models failed calls
that already expose new bytes. Four CTest entries cover happy path/fault bounds,
set uncertainty, commit uncertainty, and startup. This is **not** Espressif NVS
emulation: it does not model page wear, flash erases, physical atomicity, garbage
collection, or reboot recovery. Other core tests still cover record migration
and journal/evaluator behavior.

The unchanged `firmware-esp-idf` CI job builds the real component, custom
partition table, and firmware against the pinned toolchain; `firmware-host` runs
all native tests. Actual run URLs and outcomes belong in the associated PR.
Local Docker cross-build was requested on 2026-09-14 but blocked by the cron
approval gate before execution; no local cross-build result is claimed.

Remaining #5/#7 gates: execution on ESP32, max-size/fragmentation/OOM behavior,
NVS latency and watchdog budget, controlled set/commit power cuts, flash wear,
100 physical power cycles, runtime/RTC/boot-ID wiring, user-facing fault UI,
physical-confirmed reset, secure storage/update policy, and documented backup
and partition-upgrade recovery. No alarm reliability or fabrication-readiness
claim follows from these host checks or a successful cross-build.
