#!/usr/bin/env bash
set -euo pipefail

expected_flutter="3.47.2"
expected_dart="3.13.2"
flutter_bin="${FLUTTER_BIN:-flutter}"

flutter_version="$($flutter_bin --version | sed -n '1s/^Flutter \([^ ]*\).*/\1/p')"
dart_bin="$(dirname "$(command -v "$flutter_bin")")/dart"
dart_version="$($dart_bin --version 2>&1 | sed -n 's/^Dart SDK version: \([^ ]*\).*/\1/p')"

if [[ "$flutter_version" != "$expected_flutter" ]]; then
  echo "ERROR: expected Flutter $expected_flutter, found ${flutter_version:-unknown}" >&2
  exit 1
fi

if [[ "$dart_version" != "$expected_dart" ]]; then
  echo "ERROR: expected Dart $expected_dart, found ${dart_version:-unknown}" >&2
  exit 1
fi

echo "PASS: Flutter $flutter_version / Dart $dart_version"
