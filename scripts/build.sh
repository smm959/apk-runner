#!/usr/bin/env bash
# Сборка APK Runner.app из исходников.
#
#   ./scripts/build.sh            собрать в ./build
#   ./scripts/build.sh --install  собрать и положить в /Applications
#
# Требуется Xcode Command Line Tools (swiftc) и macOS 14+ на Apple Silicon.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/build}"
APP="$OUT/APK Runner.app"
SRC="$ROOT/src"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Info.plist")"

echo "==> Сборка бинарника"
mkdir -p "$OUT"
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI \
  -o "$OUT/APKRunner" "$SRC/APKRunnerApp.swift"

echo "==> Иконка"
swift "$SRC/makeicon.swift" "$OUT/icon" >/dev/null
if [ -f "$OUT/icon/AppIcon.iconset/icon_512x512@2x.png" ]; then
  iconutil -c icns "$OUT/icon/AppIcon.iconset" -o "$OUT/AppIcon.icns"
fi

echo "==> Сборка бандла"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/APKRunner" "$APP/Contents/MacOS/APKRunner"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
[ -f "$OUT/AppIcon.icns" ] && cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/APKRunner"

echo "==> Подпись (ad-hoc)"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"

if [ "${1:-}" = "--install" ]; then
  echo "==> Установка в /Applications"
  rm -rf "/Applications/APK Runner.app"
  cp -R "$APP" "/Applications/APK Runner.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "/Applications/APK Runner.app"
  echo "Готово: /Applications/APK Runner.app"
else
  echo "Готово: $APP"
  echo "Установить: ./scripts/build.sh --install"
fi
