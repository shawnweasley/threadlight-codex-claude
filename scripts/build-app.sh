#!/bin/bash
set -euo pipefail
THREADLIGHT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$THREADLIGHT_ROOT"
THREADLIGHT_MODE=release
if [[ "${1:-}" == "--debug" ]]; then THREADLIGHT_MODE=debug; fi
swift build -c "$THREADLIGHT_MODE" --product Threadlight
THREADLIGHT_BIN="$(swift build -c "$THREADLIGHT_MODE" --show-bin-path)"
THREADLIGHT_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/threadlight.XXXXXX")"
trap 'rm -rf "$THREADLIGHT_STAGE"' EXIT
THREADLIGHT_APP="$THREADLIGHT_STAGE/Threadlight.app"
mkdir -p "$THREADLIGHT_APP/Contents/MacOS" "$THREADLIGHT_APP/Contents/Resources"
cp "$THREADLIGHT_BIN/Threadlight" "$THREADLIGHT_APP/Contents/MacOS/Threadlight"
cp Assets/ThirdParty/Codex.icns "$THREADLIGHT_APP/Contents/Resources/Threadlight.icns"
ditto "$THREADLIGHT_BIN/Threadlight_Threadlight.bundle" "$THREADLIGHT_APP/Contents/Resources/Threadlight_Threadlight.bundle"
cat > "$THREADLIGHT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.threadlight.menubar</string>
<key>CFBundleName</key><string>Threadlight</string>
<key>CFBundleDisplayName</key><string>对话灯</string>
<key>CFBundleExecutable</key><string>Threadlight</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Threadlight</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string></array>
</dict></plist>
PLIST
printf 'APPL????' > "$THREADLIGHT_APP/Contents/PkgInfo"
xattr -cr "$THREADLIGHT_APP"
if [[ -n "${THREADLIGHT_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$THREADLIGHT_SIGN_IDENTITY" "$THREADLIGHT_APP"
else
    codesign --force --sign - "$THREADLIGHT_APP"
fi
codesign --verify --deep --strict "$THREADLIGHT_APP"
mkdir -p build
ditto "$THREADLIGHT_APP" build/Threadlight.app
xattr -cr build/Threadlight.app
codesign --verify --deep --strict build/Threadlight.app
echo "Built: $THREADLIGHT_ROOT/build/Threadlight.app"
