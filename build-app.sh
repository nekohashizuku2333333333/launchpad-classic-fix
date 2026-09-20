#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
BIN="$PWD/.build/out/Products/Release/LauncherX"
rm -f "$BIN"
set +e
swift build -c release --disable-sandbox --scratch-path "$PWD/.build" -debug-info-format none \
  --arch arm64 --arch x86_64
BUILD_STATUS=$?
set -e
if [[ ! -x "$BIN" ]]; then
  echo "Build failed before producing an executable (status $BUILD_STATUS)." >&2
  exit "$BUILD_STATUS"
fi
APP="dist/Launchpad Classic.app"
SPARKLE_FRAMEWORK="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "The verified Sparkle framework is missing." >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/LauncherX"
cp Info.plist "$APP/Contents/Info.plist"
ditto --norsrc --noqtn "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
ICON_SOURCE="$PWD/AppIcon.icns"
if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "AppIcon.icns is missing." >&2
  exit 1
fi
ditto --norsrc --noqtn "$ICON_SOURCE" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "$APP"
