# Dawn Dock companion bootstrap

This is an offline, in-memory Flutter demo backed by a fake device. Its Dart
application behavior uses no account, network operation, runtime permission,
telemetry, or persistence. The displayed next alarm is illustrative and is not
derived from the current time. The demo never executes an alarm or sends a
confirmation to real hardware.

The screen lets a reviewer preview one hardcoded schedule change, cancel it, or
explicitly apply it to fake state. Applying advances the in-memory revision once
and produces a demo-only receipt. **Reset demo** restores the initial state. The
controller is intentionally non-persistent, so restoring the initial state after
a real app restart is implementation intent, not measured evidence. The host
test only removes and reconstructs the widget tree within the same test process.

This bootstrap is not evidence of pairing, transport, protocol conformance,
device storage, calendar import, backup/export, notifications, or alarm
execution. Those remain part of open parent issue #6. The architectural and
privacy boundaries are defined in [system architecture](../docs/system-architecture.md),
the [threat model](../docs/threat-model.md), and the future
[protocol](../docs/protocol.md).

## Toolchain and quickstart

The repository pins Flutter 3.47.2 and its bundled Dart 3.13.2 in
`.flutter-version`, CI, and `tool/verify_flutter_version.sh`. With the approved
SDK installed at `/tmp/flutter-3.47.2`:

```bash
cd app
FLUTTER_BIN=/tmp/flutter-3.47.2/bin/flutter ./tool/verify_flutter_version.sh
/tmp/flutter-3.47.2/bin/flutter pub get --enforce-lockfile
/tmp/flutter-3.47.2/bin/dart format --output=none --set-exit-if-changed lib test
/tmp/flutter-3.47.2/bin/flutter analyze
/tmp/flutter-3.47.2/bin/flutter test --coverage
/tmp/flutter-3.47.2/bin/flutter run
```

`flutter run` needs an Android or iOS development target configured on the
host. Local widget tests are host software evidence, not a physical-device test.

The Android debug and profile manifests declare `android.permission.INTERNET`
for Flutter development tooling. iOS development tooling may also use the local
network. Those tooling behaviors are separate from the fake demo's application
behavior. The current build gates are development builds and do not prove final
release permission configuration; release manifest and packaged-app permission
review remain open.

Android and iOS editable projects are committed. The companion CI workflow
will run quality checks, compile an Android debug APK, and compile an unsigned
iOS simulator app without executing a simulator. CI results are not claimed
until that workflow actually runs.

Windows and macOS desktop targets are not enabled yet. In the future, from
`app/` on appropriately configured hosts, enable them with:

```bash
flutter create --platforms=windows,macos .
```

Before enabling desktop targets, review the generated changes and retain the
pinned SDK and fake-only boundary.

## Accessibility evidence and gaps

Widget tests exercise semantic status labels, 48 logical-pixel action targets,
AA text/theme contrast calculations, logical Tab/Enter operation, a 320 logical
pixel layout at 200% text scaling, and reduced-motion behavior. Physical screen
reader, switch-control, platform high-contrast, and real-device usability tests
remain open.
