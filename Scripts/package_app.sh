#!/usr/bin/env bash
set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# APP_NAME is the SwiftPM build product (module) name; APP_DISPLAY_NAME is the
# user-facing name used for the .app folder, executable, and bundle name.
APP_NAME=${APP_NAME:-JackApp}
APP_DISPLAY_NAME=${APP_DISPLAY_NAME:-Silky}

# Keep bundle IDs unique per workspace path for DEV builds so macOS
# TCC/LaunchServices never confuse this app with another clone of the same
# project. Release/distribution builds MUST use the stable bundle id, or
# Sparkle cannot update the installed app in place (RELEASE_BUILD=1).
DEFAULT_BUNDLE_ID="com.jack.app.v2"
RELEASE_BUILD=${RELEASE_BUILD:-0}
if [[ "$RELEASE_BUILD" != "1" ]] && command -v shasum >/dev/null 2>&1; then
  WORKSPACE_HASH=$(printf '%s' "$ROOT" | shasum -a 1 | awk '{print substr($1,1,10)}')
  DEFAULT_BUNDLE_ID="com.jack.app.v2.ws${WORKSPACE_HASH}"
fi
BUNDLE_ID=${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}

# Sparkle auto-update configuration (see Sources/JackApp/Updater/).
SPARKLE_FEED_URL=${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/Thiagoxp95/jack/main/appcast.xml}
SPARKLE_PUBLIC_ED_KEY=${SPARKLE_PUBLIC_ED_KEY:-6B0KocpR2cegqfvRlSVZ+JdMXQ/uuLcJlEf/AAgH90Y=}
MACOS_MIN_VERSION=${MACOS_MIN_VERSION:-14.0}
MENU_BAR_APP=${MENU_BAR_APP:-0}
SIGNING_MODE=${SIGNING_MODE:-}
APP_IDENTITY=${APP_IDENTITY:-}

# Prefer a stable signing identity when available, unless ad-hoc was explicitly requested.
if [[ -z "$APP_IDENTITY" && "$SIGNING_MODE" != "adhoc" ]]; then
  if command -v security >/dev/null 2>&1; then
    APP_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
      | awk '/[0-9]+\) [0-9A-F]{40} / { print $2; exit }')
  fi
fi

if [[ -f "$ROOT/version.env" ]]; then
  source "$ROOT/version.env"
else
  MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
  BUILD_NUMBER=${BUILD_NUMBER:-1}
fi

ARCH_LIST=( ${ARCHES:-} )
if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  HOST_ARCH=$(uname -m)
  ARCH_LIST=("$HOST_ARCH")
fi

for ARCH in "${ARCH_LIST[@]}"; do
  swift build -c "$CONF" --arch "$ARCH"
done

APP="$ROOT/${APP_DISPLAY_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Convert Icon.iconset to Icon.icns if present (requires iconutil).
ICON_SOURCE="$ROOT/Icon.iconset"
ICON_TARGET="$ROOT/Icon.icns"
if [[ -d "$ICON_SOURCE" ]]; then
  iconutil --convert icns --output "$ICON_TARGET" "$ICON_SOURCE"
fi

LSUI_VALUE="false"
if [[ "$MENU_BAR_APP" == "1" ]]; then
  LSUI_VALUE="true"
fi

BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>NSMicrophoneUsageDescription</key><string>Silky needs microphone access to transcribe speech.</string>
    <key>LSUIElement</key><${LSUI_VALUE}/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>BuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
    <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
</dict>
</plist>
PLIST

build_product_path() {
  local name="$1"
  local arch="$2"
  case "$arch" in
    arm64|x86_64) echo ".build/${arch}-apple-macosx/$CONF/$name" ;;
    *) echo ".build/$CONF/$name" ;;
  esac
}

verify_binary_arches() {
  local binary="$1"; shift
  local expected=("$@")
  local actual
  actual=$(lipo -archs "$binary")
  local actual_count expected_count
  actual_count=$(wc -w <<<"$actual" | tr -d ' ')
  expected_count=${#expected[@]}
  if [[ "$actual_count" -ne "$expected_count" ]]; then
    echo "ERROR: $binary arch mismatch (expected: ${expected[*]}, actual: ${actual})" >&2
    exit 1
  fi
  for arch in "${expected[@]}"; do
    if [[ "$actual" != *"$arch"* ]]; then
      echo "ERROR: $binary missing arch $arch (have: ${actual})" >&2
      exit 1
    fi
  done
}

install_binary() {
  local name="$1"
  local dest="$2"
  local binaries=()
  for arch in "${ARCH_LIST[@]}"; do
    local src
    src=$(build_product_path "$name" "$arch")
    if [[ ! -f "$src" ]]; then
      echo "ERROR: Missing ${name} build for ${arch} at ${src}" >&2
      exit 1
    fi
    binaries+=("$src")
  done
  if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
    lipo -create "${binaries[@]}" -output "$dest"
  else
    cp "${binaries[0]}" "$dest"
  fi
  chmod +x "$dest"
  verify_binary_arches "$dest" "${ARCH_LIST[@]}"
}

install_binary "$APP_NAME" "$APP/Contents/MacOS/$APP_DISPLAY_NAME"

# Bundle the MCP server CLI next to the app binary (agents exec it directly).
install_binary "JackMCP" "$APP/Contents/MacOS/JackMCP"

# Bundle app resources (if any).
APP_RESOURCES_DIR="$ROOT/Sources/$APP_NAME/Resources"
if [[ -d "$APP_RESOURCES_DIR" ]]; then
  cp -R "$APP_RESOURCES_DIR/." "$APP/Contents/Resources/"
fi

# SwiftPM resource bundles are emitted next to the built binary.
PREFERRED_BUILD_DIR="$(dirname "$(build_product_path "$APP_NAME" "${ARCH_LIST[0]}")")"
shopt -s nullglob
SWIFTPM_BUNDLES=("${PREFERRED_BUILD_DIR}/"*.bundle)
shopt -u nullglob
if [[ ${#SWIFTPM_BUNDLES[@]} -gt 0 ]]; then
  for bundle in "${SWIFTPM_BUNDLES[@]}"; do
    cp -R "$bundle" "$APP/Contents/Resources/"
  done
fi

# Embed frameworks if any exist in the build folder.
FRAMEWORK_DIRS=(".build/$CONF" ".build/${ARCH_LIST[0]}-apple-macosx/$CONF")
for dir in "${FRAMEWORK_DIRS[@]}"; do
  if compgen -G "${dir}/*.framework" >/dev/null; then
    cp -R "${dir}/"*.framework "$APP/Contents/Frameworks/"
    chmod -R a+rX "$APP/Contents/Frameworks"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_DISPLAY_NAME"
    break
  fi
done

if [[ -f "$ICON_TARGET" ]]; then
  cp "$ICON_TARGET" "$APP/Contents/Resources/Icon.icns"
fi

# Ensure contents are writable before stripping attributes and signing.
chmod -R u+w "$APP"

# Strip extended attributes to prevent AppleDouble files that break code sealing.
xattr -cr "$APP"
find "$APP" -name '._*' -delete

ENTITLEMENTS_DIR="$ROOT/.build/entitlements"
DEFAULT_ENTITLEMENTS="$ENTITLEMENTS_DIR/${APP_NAME}.entitlements"
mkdir -p "$ENTITLEMENTS_DIR"

APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-$DEFAULT_ENTITLEMENTS}
if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
  cat > "$APP_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
PLIST
fi

# For hardened runtime development builds, keep microphone entitlement present
# so TCC microphone authorization can be granted for this signed app identity.
ENABLE_AUDIO_INPUT_ENTITLEMENT=${ENABLE_AUDIO_INPUT_ENTITLEMENT:-1}
if [[ "$ENABLE_AUDIO_INPUT_ENTITLEMENT" == "1" ]]; then
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$APP_ENTITLEMENTS" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Set :com.apple.security.device.audio-input true' "$APP_ENTITLEMENTS" >/dev/null
  else
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.device.audio-input bool true' "$APP_ENTITLEMENTS" >/dev/null
  fi
fi

if [[ "$SIGNING_MODE" == "adhoc" || -z "$APP_IDENTITY" ]]; then
  CODESIGN_ARGS=(--force --sign "-")
  echo "Signing mode: ad-hoc"
else
  # Hardened runtime enforces library validation, which requires every nested
  # binary to share the main executable's Team ID. A local self-signed dev cert
  # has no Team ID, so Sparkle.framework fails to load and the app dies at
  # launch. Only Developer ID builds (the ones that get notarized) need it.
  IDENTITY_NAME=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -v id="$APP_IDENTITY" '$0 ~ id { sub(/^[^"]*"/, ""); sub(/"$/, ""); print; exit }')
  if [[ "$IDENTITY_NAME" == *"Developer ID"* || "$APP_IDENTITY" == *"Developer ID"* ]]; then
    CODESIGN_ARGS=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
    echo "Signing mode: identity ($APP_IDENTITY) + hardened runtime"
  else
    CODESIGN_ARGS=(--force --sign "$APP_IDENTITY")
    echo "Signing mode: identity ($APP_IDENTITY), local dev (no hardened runtime)"
  fi
fi

# Sign embedded frameworks and their nested binaries before the app bundle.
sign_frameworks() {
  local fw
  for fw in "$APP/Contents/Frameworks/"*.framework; do
    if [[ ! -d "$fw" ]]; then
      continue
    fi
    while IFS= read -r -d '' bin; do
      codesign "${CODESIGN_ARGS[@]}" "$bin"
    done < <(find "$fw" -type f -perm -111 -print0)
    codesign "${CODESIGN_ARGS[@]}" "$fw"
  done
}
sign_frameworks

# Nested binaries must be signed before the outer bundle seal.
codesign "${CODESIGN_ARGS[@]}" "$APP/Contents/MacOS/JackMCP"

codesign "${CODESIGN_ARGS[@]}" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP"

echo "Created $APP"
