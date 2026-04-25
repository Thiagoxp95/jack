#!/usr/bin/env bash
# Build, sign, and install JackApp to /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME=${APP_NAME:-JackApp}
APP_DISPLAY_NAME=${APP_DISPLAY_NAME:-Jack}
INSTALL_DIR="/Applications"
INSTALLED_APP="${INSTALL_DIR}/${APP_DISPLAY_NAME}.app"
LOCAL_APP="${ROOT}/${APP_NAME}.app"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# 1. Quit running app
log "Quitting ${APP_DISPLAY_NAME}"
osascript -e "tell application \"${APP_DISPLAY_NAME}\" to quit" 2>/dev/null || true
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 0.5

# 2. Build & package (release, native arch)
log "Building release"
ARCHES="$(uname -m)" "${ROOT}/Scripts/package_app.sh" release

[[ -d "$LOCAL_APP" ]] || fail "package_app.sh did not produce ${LOCAL_APP}"

# 3. Replace in /Applications
log "Installing to ${INSTALLED_APP}"
rm -rf "${INSTALLED_APP}"
cp -R "${LOCAL_APP}" "${INSTALLED_APP}"

# 4. Launch
log "Launching ${APP_DISPLAY_NAME}"
open "${INSTALLED_APP}"

log "Done"
