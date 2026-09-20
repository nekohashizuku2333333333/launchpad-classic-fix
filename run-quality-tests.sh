#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PWD/.build/quality-tests"

swiftc -parse-as-library \
  -warnings-as-errors \
  Sources/LauncherX/Model.swift \
  Sources/LauncherX/FileSystemServices.swift \
  Sources/LauncherX/ScrollWheelMonitor.swift \
  Sources/LauncherX/LaunchpadLayout.swift \
  Sources/LauncherX/ContentView.swift \
  QualityTests/LauncherQualityTests.swift \
  -o .build/quality-tests/LauncherQualityTests \
  -framework SwiftUI \
  -framework AppKit

.build/quality-tests/LauncherQualityTests
