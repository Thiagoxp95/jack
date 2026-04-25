#!/usr/bin/env bash
# Kill running instances, package, relaunch, verify.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME=${APP_NAME:-JackApp}
APP_BUNDLE="${ROOT_DIR}/${APP_NAME}.app"
APP_PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
DEBUG_PROCESS_PATTERN="${ROOT_DIR}/.build/debug/${APP_NAME}"
RELEASE_PROCESS_PATTERN="${ROOT_DIR}/.build/release/${APP_NAME}"
RUN_TESTS=0
RELEASE_ARCHES=""
BUILD_CONF="debug"
DO_ARCHIVE=0

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "${arg}" in
    --test|-t) RUN_TESTS=1 ;;
    --release) BUILD_CONF="release" ;;
    --release-universal) RELEASE_ARCHES="arm64 x86_64"; BUILD_CONF="release" ;;
    --release-arches=*) RELEASE_ARCHES="${arg#*=}"; BUILD_CONF="release" ;;
    --archive) DO_ARCHIVE=1; BUILD_CONF="release" ;;
    --help|-h)
      log "Usage: $(basename "$0") [--test] [--release] [--archive] [--release-universal] [--release-arches=\"arm64 x86_64\"]"
      exit 0
      ;;
  esac
done

log "==> Killing existing ${APP_NAME} instances"
pkill -f "${APP_PROCESS_PATTERN}" 2>/dev/null || true
pkill -f "${DEBUG_PROCESS_PATTERN}" 2>/dev/null || true
pkill -f "${RELEASE_PROCESS_PATTERN}" 2>/dev/null || true
pkill -x "${APP_NAME}" 2>/dev/null || true

if [[ "${RUN_TESTS}" == "1" ]]; then
  log "==> swift test"
  swift test -q
fi

HOST_ARCH="$(uname -m)"
ARCHES_VALUE="${HOST_ARCH}"
if [[ -n "${RELEASE_ARCHES}" ]]; then
  ARCHES_VALUE="${RELEASE_ARCHES}"
fi

log "==> package app"
PACKAGE_SIGNING_MODE="${SIGNING_MODE:-}"
PACKAGE_APP_IDENTITY="${APP_IDENTITY:-}"

if [[ -z "${PACKAGE_SIGNING_MODE}" && -z "${PACKAGE_APP_IDENTITY}" ]]; then
  # Prefer a stable code-signing identity if one is available, so macOS TCC
  # keeps Accessibility/Input Monitoring grants across rebuilds.
  if command -v security >/dev/null 2>&1; then
    DETECTED_IDENTITY_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk '/[0-9]+\) [0-9A-F]{40} / { print $2; exit }')"
    if [[ -n "${DETECTED_IDENTITY_HASH}" ]]; then
      PACKAGE_APP_IDENTITY="${DETECTED_IDENTITY_HASH}"
    fi
  fi
fi

if [[ -z "${PACKAGE_SIGNING_MODE}" && -z "${PACKAGE_APP_IDENTITY}" ]]; then
  PACKAGE_SIGNING_MODE="adhoc"
fi

if [[ -n "${PACKAGE_APP_IDENTITY}" ]]; then
  log "==> using signing identity: ${PACKAGE_APP_IDENTITY}"
else
  log "==> using ad-hoc signing (permissions may reset after rebuilds)"
fi

if [[ "${DO_ARCHIVE}" == "1" ]]; then
  log "==> xcodebuild archive (arm64 only)"
  ARCHIVE_PATH="${ROOT_DIR}/${APP_NAME}.xcarchive"
  rm -rf "${ARCHIVE_PATH}"
  xcodebuild archive \
    -scheme "${APP_NAME}" \
    -destination "generic/platform=macOS" \
    -archivePath "${ARCHIVE_PATH}" \
    EXCLUDED_ARCHS=x86_64
  log "OK: Archive created at ${ARCHIVE_PATH}"
  log "Open in Xcode: open ${ARCHIVE_PATH}"
  exit 0
fi

if [[ -n "${PACKAGE_SIGNING_MODE}" ]]; then
  SIGNING_MODE="${PACKAGE_SIGNING_MODE}" APP_IDENTITY="${PACKAGE_APP_IDENTITY}" ARCHES="${ARCHES_VALUE}" "${ROOT_DIR}/Scripts/package_app.sh" "${BUILD_CONF}"
else
  APP_IDENTITY="${PACKAGE_APP_IDENTITY}" ARCHES="${ARCHES_VALUE}" "${ROOT_DIR}/Scripts/package_app.sh" "${BUILD_CONF}"
fi

if [[ -f "${APP_BUNDLE}/Contents/Info.plist" ]]; then
  APP_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_BUNDLE}/Contents/Info.plist")
  log "==> bundle id: ${APP_BUNDLE_ID}"
fi

log "==> launch app"
if ! open "${APP_BUNDLE}"; then
  log "WARN: open failed; launching binary directly."
  "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 &
  disown
fi

for _ in {1..10}; do
  if pgrep -f "${APP_PROCESS_PATTERN}" >/dev/null 2>&1; then
    log "OK: ${APP_NAME} is running."
    exit 0
  fi
  sleep 0.4
done
fail "App exited immediately. Check crash logs in Console.app (User Reports)."
