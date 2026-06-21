#!/usr/bin/env bash
#
# push.sh — build the app and install it on a device in one go.
#
# Default target is the Pixel 6a over Wi-Fi (fixed adb tcpip port 5555).
# See CLAUDE.md "adb tcpip" notes — if the phone rebooted, re-enable once
# over USB:  adb -d tcpip 5555
#
# Usage:
#   ./push.sh                      # wifi (default) -> staging debug -> phone
#   ./push.sh -m usb               # first USB device
#   ./push.sh -m wifi -t 192.168.1.50:5555
#   ./push.sh -f prod -r           # prod flavor, release build
#   ./push.sh -m emulator          # first running emulator/device flutter sees
#
# Flags:
#   -m  method: wifi | usb | emulator   (default: wifi)
#   -t  target: adb device id / ip:port (default: $PHONE_TARGET below)
#   -f  flavor: dev | staging | prod    (default: staging)
#   -r  release build                   (default: debug)
#   -h  help

set -euo pipefail

# --- defaults ---------------------------------------------------------------
PHONE_TARGET="192.168.1.210:5555"   # Pixel 6a, fixed tcpip port
METHOD="wifi"
TARGET=""
FLAVOR="staging"
MODE="debug"

# adb may not be on PATH; find it the same way we do elsewhere.
ADB="$(command -v adb || true)"
for cand in "$HOME/Android/Sdk/platform-tools/adb" \
            "$HOME/Library/Android/sdk/platform-tools/adb"; do
  [ -z "$ADB" ] && [ -x "$cand" ] && ADB="$cand"
done
[ -z "$ADB" ] && { echo "error: adb not found" >&2; exit 1; }

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":m:t:f:rh" opt; do
  case "$opt" in
    m) METHOD="$OPTARG" ;;
    t) TARGET="$OPTARG" ;;
    f) FLAVOR="$OPTARG" ;;
    r) MODE="release" ;;
    h) usage 0 ;;
    \?) echo "unknown flag: -$OPTARG" >&2; usage 1 ;;
    :) echo "flag -$OPTARG needs a value" >&2; usage 1 ;;
  esac
done

# --- resolve the device -----------------------------------------------------
case "$METHOD" in
  wifi)
    DEVICE="${TARGET:-$PHONE_TARGET}"
    echo ">> connecting to $DEVICE over wifi"
    "$ADB" connect "$DEVICE" >/dev/null 2>&1 || true
    # Verify it actually answers; mDNS/tcpip can go stale silently.
    if ! "$ADB" -s "$DEVICE" get-state >/dev/null 2>&1; then
      echo "error: $DEVICE is not reachable." >&2
      echo "  - phone & laptop on the same wifi?" >&2
      echo "  - rebooted? re-enable once over USB:  $ADB -d tcpip 5555" >&2
      echo "  - find the current port:  $ADB mdns services" >&2
      exit 1
    fi
    ;;
  usb)
    DEVICE="${TARGET:-$("$ADB" devices | awk 'NR>1 && $2=="device" && $1!~":" {print $1; exit}')}"
    [ -z "$DEVICE" ] && { echo "error: no USB device found" >&2; exit 1; }
    echo ">> using USB device $DEVICE"
    ;;
  emulator)
    DEVICE="${TARGET:-$("$ADB" devices | awk 'NR>1 && $1~/^emulator-/ {print $1; exit}')}"
    [ -z "$DEVICE" ] && { echo "error: no running emulator found" >&2; exit 1; }
    echo ">> using emulator $DEVICE"
    ;;
  *)
    echo "error: unknown method '$METHOD' (want wifi|usb|emulator)" >&2; exit 1 ;;
esac

# --- build ------------------------------------------------------------------
echo ">> building $FLAVOR $MODE apk"
flutter build apk --"$MODE" --flavor "$FLAVOR"

APK="build/app/outputs/flutter-apk/app-${FLAVOR}-${MODE}.apk"
[ -f "$APK" ] || { echo "error: expected APK not found: $APK" >&2; exit 1; }

# --- install ----------------------------------------------------------------
echo ">> installing $APK -> $DEVICE"
"$ADB" -s "$DEVICE" install -r "$APK"

echo ">> done"
