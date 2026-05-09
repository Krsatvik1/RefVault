#!/usr/bin/env bash
# One-shot build: fetch Ollama → build .app → package .dmg.
#
# Usage:
#   ./scripts/build.sh         # full build, output to dist/RefVault.dmg
#   ./scripts/build.sh app     # stop after .app, no .dmg
#   FORCE=1 ./scripts/build.sh # re-fetch Ollama even if already vendored
#
# Each phase is idempotent: rerunning skips work whose inputs haven't
# changed (Ollama binary download, swift compile cache).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/dist"
VENDOR_DIR="$REPO_ROOT/Vendored/ollama"
OLLAMA_BIN="$VENDOR_DIR/ollama"
SOURCE_ICON="$REPO_ROOT/Sources/RefVault/Resources/icons/AppIcon.png"

APP_NAME="RefVault"
BUNDLE_ID="com.refvault.app"
APP_VERSION="${REFVAULT_VERSION:-0.1.0}"
BUILD_NUMBER="${REFVAULT_BUILD:-1}"
MIN_MACOS="13.0"

STOP_AFTER="${1:-dmg}"

cd "$REPO_ROOT"

# ─── 1. Fetch Ollama ─────────────────────────────────────────────────
# Pulls the `ollama` binary out of Apple's official Ollama-darwin.zip.
# Why extract from the .app instead of grabbing a standalone asset:
# Ollama's release set isn't consistent across versions, but the .app
# artifact has been stable and bundles the universal arm64+x86_64
# binary we need.
if [[ ! -x "$OLLAMA_BIN" || -n "${FORCE:-}" ]]; then
    echo "▶ fetching ollama"
    mkdir -p "$VENDOR_DIR"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    URL="https://github.com/ollama/ollama/releases/${OLLAMA_VERSION:+download/$OLLAMA_VERSION/}${OLLAMA_VERSION:+}Ollama-darwin.zip"
    [[ -z "${OLLAMA_VERSION:-}" ]] && URL="https://github.com/ollama/ollama/releases/latest/download/Ollama-darwin.zip"
    curl --fail --location --progress-bar -o "$TMP/Ollama-darwin.zip" "$URL"
    unzip -q "$TMP/Ollama-darwin.zip" -d "$TMP/unpacked"
    SRC=""
    for c in "$TMP/unpacked/Ollama.app/Contents/Resources/ollama" \
             "$TMP/unpacked/Ollama.app/Contents/MacOS/ollama" \
             "$TMP/unpacked/ollama"; do
        [[ -x "$c" ]] && SRC="$c" && break
    done
    [[ -z "$SRC" ]] && { echo "could not find ollama inside zip" >&2; exit 1; }
    cp "$SRC" "$OLLAMA_BIN"
    chmod +x "$OLLAMA_BIN"
    rm -rf "$TMP"
    trap - EXIT
else
    echo "▶ ollama already vendored ($("$OLLAMA_BIN" --version 2>&1 | head -1))"
fi

# ─── 2. Build the .app ───────────────────────────────────────────────
# Stage in /tmp (not Spotlight-indexed) so Finder can't race in to
# attach com.apple.FinderInfo between our xattr clean and codesign,
# which produced a "code has no resources but signature indicates they
# must be present" failure when staging in /Users.
echo "▶ swift build -c release"
swift build -c release

BUILD_DIR="$REPO_ROOT/.build/release"
BIN="$BUILD_DIR/$APP_NAME"
RESOURCE_BUNDLE="$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle"
[[ -x "$BIN" ]] || { echo "$BIN missing" >&2; exit 1; }
[[ -d "$RESOURCE_BUNDLE" ]] || { echo "$RESOURCE_BUNDLE missing — SwiftPM bundle name changed?" >&2; exit 1; }
[[ -f "$SOURCE_ICON" ]] || { echo "$SOURCE_ICON missing — drop a 1024px PNG there" >&2; exit 1; }

echo "▶ wrapping into RefVault.app"
STAGE="$(mktemp -d -t refvault-build)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/RefVault.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# ditto with --norsrc/--noextattr/--noacl drops the metadata that
# codesign refuses to seal around. Plain `cp -R` would attach
# com.apple.provenance to every file.
ditto --norsrc --noextattr --noacl "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"
ditto --norsrc --noextattr --noacl "$RESOURCE_BUNDLE" "$APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
ditto --norsrc --noextattr --noacl "$OLLAMA_BIN" "$APP/Contents/Resources/ollama"
chmod +x "$APP/Contents/Resources/ollama"

# .icns from the source 1024px PNG. sips upscales/downsamples to every
# size Apple wants in an iconset; iconutil packages them.
ICONSET="$STAGE/RefVault.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 64 128 256 512 1024; do
    sips -z "$SIZE" "$SIZE" "$SOURCE_ICON" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
done
cp "$ICONSET/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
rm "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
iconutil -c icns -o "$APP/Contents/Resources/RefVault.icns" "$ICONSET"

# Info.plist.
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>RefVault</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>RefVault — local design reference library</string>
    <key>NSDesktopFolderUsageDescription</key><string>RefVault watches your Desktop for new screenshots so it can index them.</string>
</dict>
</plist>
EOF

# Ad-hoc sign. Inside-out. No `--options runtime` (hardened runtime
# without entitlements = "damaged" launch failure). No `--deep` and
# no `--identifier` on the outer call (combined, they made codesign
# take a Mach-O codepath instead of a bundle codepath, leaving
# _CodeSignature/CodeResources missing).
codesign --force --sign - "$APP/Contents/Resources/ollama"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP" >/dev/null

# Move into place.
mkdir -p "$DIST"
rm -rf "$DIST/RefVault.app"
ditto --norsrc --noextattr --noacl "$APP" "$DIST/RefVault.app"
echo "▶ built $DIST/RefVault.app ($(du -sh "$DIST/RefVault.app" | awk '{print $1}'))"

if [[ "$STOP_AFTER" == "app" ]]; then
    exit 0
fi

# ─── 3. Package the .zip ─────────────────────────────────────────────
# Why ZIP and not DMG: macOS Sequoia (15+) added a Gatekeeper check on
# disk images themselves. A quarantined, ad-hoc signed .dmg trips that
# check on mount with "Apple could not verify ... is free of malware"
# — separate from the .app's own unidentified-developer prompt — and
# the user has to approve BOTH (DMG and .app) via System Settings.
# ZIPs aren't subject to the disk-image check, so the user only deals
# with one Privacy & Security override (for the .app) instead of two.
#
# `ditto -c -k --keepParent` is the only zip implementation on macOS
# that correctly preserves bundle structure, symlinks, extended
# attributes, and the codesign seal. Plain `zip` corrupts at least
# one of those and the extracted .app fails to launch.
echo "▶ packaging RefVault.zip"
ZIP="$DIST/RefVault.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$DIST/RefVault.app" "$ZIP"

echo "▶ built $ZIP ($(du -sh "$ZIP" | awk '{print $1}'))"
