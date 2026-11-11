#!/bin/bash
# Build dist/Toss.app from the SwiftPM release build.
#
# TDLib is a prebuilt static xcframework (TDLibFramework), downloaded once by
# SwiftPM and cached, so a build only compiles Toss's own sources.
#
# Environment:
#   TOSS_BUNDLE_ID         bundle id (default app.toast.toss); use a unique one for test builds
#   TOSS_APP_PATH          output bundle (default dist/Toss.app)
#   TOSS_VERSION           marketing version (default 1.0)
#   TOSS_SIGNING_IDENTITY  codesign identity (default: first stable local identity, else ad-hoc)
#
# Usage: ./scripts/build-app.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Xcode 27's default SwiftPM engine records the deployment target as the SDK,
# which makes AppKit serve pre-Liquid Glass controls. The native engine
# records the real SDK.
SWIFT_BUILD=(swift build --build-system native -c release)
BUNDLE_ID="${TOSS_BUNDLE_ID:-app.toast.toss}"
APP="${TOSS_APP_PATH:-$ROOT/dist/Toss.app}"
VERSION="${TOSS_VERSION:-1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "== building =="
"${SWIFT_BUILD[@]}"
BIN="$("${SWIFT_BUILD[@]}" --show-bin-path)/Toss"

echo "== assembling $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Toss"
# Debug symbols carry absolute build paths; the app doesn't need them.
strip -S "$APP/Contents/MacOS/Toss"
cp -R "$ROOT/Resources/"*.lproj "$APP/Contents/Resources/"
# App icon: built from the PNG set rendered by scripts/make-icon.py.
if [[ -d "$ROOT/Resources/AppIcon.iconset" ]]; then
    iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
elif [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Toss</string>
    <key>CFBundleDisplayName</key><string>Toss</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Toss</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Toast1</string>
</dict>
</plist>
PLIST

echo "== signing =="
IDENTITY="${TOSS_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    # A stable identity keeps Keychain access across rebuilds; ad-hoc builds
    # change identity every time and macOS asks again for the saved login.
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    while IFS= read -r line; do
        if [[ "$line" == *'"Apple Development:'* ]]; then
            IDENTITY="${line#*\"}"; IDENTITY="${IDENTITY%%\"*}"; break
        fi
    done <<< "$IDENTITIES"
fi
if [[ -z "$IDENTITY" ]]; then
    echo "signing identity: none (ad-hoc)"
    codesign --force --options runtime --timestamp=none --sign - "$APP"
else
    echo "signing identity: $IDENTITY"
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

# Never ship the build machine's paths inside the app.
if grep -aq -e "$ROOT" -e "$HOME/" "$APP/Contents/MacOS/Toss"; then
    echo "warning: binary still contains local paths" >&2
fi

echo "== done: $APP =="
echo "Install: ditto \"$APP\" /Applications/Toss.app && open /Applications/Toss.app"
