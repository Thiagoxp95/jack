#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME=${APP_NAME:-JackApp}
APP_PATH="${ROOT_DIR}/${APP_NAME}.app"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--microphone] [--accessibility] [--input-monitoring] [--screen-recording] [--all]

Resets macOS TCC permissions for the current app bundle identifier.
If no flag is provided, --all is used.
USAGE
}

RESET_MIC=0
RESET_ACCESSIBILITY=0
RESET_INPUT=0
RESET_SCREEN=0
ANY_FLAG=0

for arg in "$@"; do
  case "$arg" in
    --microphone) RESET_MIC=1; ANY_FLAG=1 ;;
    --accessibility) RESET_ACCESSIBILITY=1; ANY_FLAG=1 ;;
    --input-monitoring) RESET_INPUT=1; ANY_FLAG=1 ;;
    --screen-recording) RESET_SCREEN=1; ANY_FLAG=1 ;;
    --all) RESET_MIC=1; RESET_ACCESSIBILITY=1; RESET_INPUT=1; RESET_SCREEN=1; ANY_FLAG=1 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown option: $arg" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$ANY_FLAG" -eq 0 ]]; then
  RESET_MIC=1
  RESET_ACCESSIBILITY=1
  RESET_INPUT=1
  RESET_SCREEN=1
fi

if [[ ! -f "${APP_PATH}/Contents/Info.plist" ]]; then
  echo "ERROR: ${APP_PATH} not found. Build/package the app first." >&2
  exit 1
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist")

echo "Target bundle ID: ${BUNDLE_ID}"

if [[ "$RESET_MIC" -eq 1 ]]; then
  echo "Resetting Microphone..."
  tccutil reset Microphone "${BUNDLE_ID}" || true
fi

if [[ "$RESET_ACCESSIBILITY" -eq 1 ]]; then
  echo "Resetting Accessibility..."
  tccutil reset Accessibility "${BUNDLE_ID}" || true
fi

if [[ "$RESET_INPUT" -eq 1 ]]; then
  echo "Resetting Input Monitoring..."
  tccutil reset ListenEvent "${BUNDLE_ID}" || true
fi

if [[ "$RESET_SCREEN" -eq 1 ]]; then
  echo "Resetting Screen Recording..."
  tccutil reset ScreenCapture "${BUNDLE_ID}" || true
fi

echo "Done. Relaunch app and request permissions again."
