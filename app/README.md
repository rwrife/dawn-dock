# Companion app plan

Status: plan only; no Flutter project or build evidence exists yet.

## Responsibilities

- Discover or manually address a Dawn Dock on the local network/BLE.
- Pair with an explicit device-displayed code/QR flow and manage local credentials.
- Create recurring alarms, preview a device/app diff, and explicitly apply a revision.
- Import user-selected `.ics` files and turn relevant events into reviewable alarm suggestions.
- Display device time, next alarm, firmware/protocol version, connectivity, and diagnostics.
- Export/restore user-owned JSON backup and erase local/device data.
- Keep optional weather endpoint configuration outside the alarm-critical path.

## Target platforms and framework

Flutter stable with Dart targets Android and iOS first. Windows and macOS companions follow once shared domain/protocol code and platform adapters are stable. Platform-specific BLE, LAN discovery, file picker, secure storage, and permissions remain behind interfaces.

## Setup flow

1. User chooses LAN discovery, BLE discovery, or manual address.
2. Device opens a short physical pairing window and displays a unique code.
3. App confirms the device fingerprint/name and stores the resulting credential in platform secure storage.
4. User sets time/timezone, creates or imports alarms, reviews changes, then applies them.
5. Both sides display the same schedule revision and next alarm.

## Local data ownership

- Local storage contains paired-device metadata, schedule drafts, accepted/import provenance, and backup history.
- No account, analytics, or remote database is required.
- JSON backup and `.ics` import are documented and versioned.
- Device credentials use Keychain/Keystore or OS-equivalent secure storage.
- Users can remove one device, erase imported event details, or reset all app data.

## Permissions

- Local-network/Bluetooth permissions are requested only when the selected transport requires them.
- File access uses a user-invoked picker for `.ics` import and JSON export/restore.
- Broad calendar permission is not required for the MVP; selected-file import is preferred.
- Notifications are optional convenience reminders and never substitute for device alarm execution.
- No microphone, camera, location, contacts, or background-health permission is planned.

## Accessibility

Support screen readers, semantic labels, dynamic type, logical focus order, keyboard navigation on desktop, minimum touch targets, high contrast, reduced motion, and non-color-only status indicators. Pairing/sync success and errors must be announced accessibly.

## Protocol boundary

The app never writes raw storage or hardware state. It uses the versioned contract in `docs/protocol.md`, sends expected schedule revisions, validates device responses, and treats external data as untrusted input. Calendar-derived alarms remain suggestions until accepted.
