#!/usr/bin/env bash
# Ставит Android SDK (эмулятор + образ с Google Play) и создаёт виртуальное
# устройство, которое использует APK Runner.
#
#   ./scripts/setup-sdk.sh
#
# Занятость на диске: ~13 ГБ (SDK ~4 ГБ + данные устройства ~9 ГБ).

set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
API="${API:-36}"
BUILD_TOOLS="${BUILD_TOOLS:-36.0.0}"
IMG="system-images;android-${API};google_apis_playstore;arm64-v8a"
AVD="${AVD_NAME:-Android16}"

echo "==> SDK: $SDK"

# 1. cmdline-tools (sdkmanager)
if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  BREW_TOOLS="/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest"
  if [ -x "$BREW_TOOLS/bin/sdkmanager" ]; then
    mkdir -p "$SDK/cmdline-tools"
    cp -R "$BREW_TOOLS" "$SDK/cmdline-tools/latest"
    echo "    cmdline-tools скопированы из Homebrew"
  else
    echo "Не найдены cmdline-tools. Установи:  brew install --cask android-commandlinetools" >&2
    exit 1
  fi
fi

SDKM="$SDK/cmdline-tools/latest/bin/sdkmanager"
export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"

# 2. Лицензии и пакеты
yes | "$SDKM" --licenses >/dev/null 2>&1 || true
echo "==> Скачиваю эмулятор, platform-tools, build-tools и образ Android $API (Google Play, arm64)"
"$SDKM" "platform-tools" "platforms;android-${API}" "build-tools;${BUILD_TOOLS}" "emulator" "$IMG"

# 3. Виртуальное устройство
if "$SDK/emulator/emulator" -list-avds | grep -qx "$AVD"; then
  echo "==> Устройство $AVD уже есть"
else
  echo "==> Создаю устройство $AVD (Pixel 10, Android $API)"
  # avdmanager может ругаться на devices.xml внутри образа, но AVD всё равно создаётся
  echo "no" | "$SDK/cmdline-tools/latest/bin/avdmanager" create avd \
    -n "$AVD" -k "$IMG" -d pixel_10 --force >/dev/null 2>&1 || true

  CFG="$HOME/.android/avd/$AVD.avd/config.ini"
  if [ ! -f "$CFG" ]; then
    echo "Не удалось создать AVD $AVD — смотри вывод avdmanager" >&2
    exit 1
  fi

  # Play Store и разумные ресурсы
  python3 - "$CFG" <<'PY'
import re, sys
path = sys.argv[1]
wanted = {
    "PlayStore.enabled": "yes",
    "hw.gpu.enabled": "yes",
    "hw.gpu.mode": "auto",
    "hw.ramSize": "6144",
    "vm.heapSize": "576",
    "hw.cpu.ncore": "6",
    "hw.keyboard": "yes",
    "disk.dataPartition.size": "16G",
}
lines = open(path).read().splitlines()
out, seen = [], set()
for line in lines:
    m = re.match(r"^([^=]+)=(.*)$", line)
    key = m.group(1) if m else None
    if key in wanted:
        out.append(f"{key}={wanted[key]}")
        seen.add(key)
    else:
        out.append(line)
out += [f"{k}={v}" for k, v in wanted.items() if k not in seen]
open(path, "w").write("\n".join(out) + "\n")
PY
fi

echo
echo "Готово."
echo "  Проверить:  $SDK/emulator/emulator -list-avds"
echo "  Собрать:    ./scripts/build.sh --install"
echo "  Хелпер:     sudo cp scripts/apk-run /usr/local/bin/   (или ~/.local/bin)"
