#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "==> [1/4] Building LaunchOS replica with Swift Package Manager..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/LaunchOS"
APP_BUNDLE="$PROJECT_DIR/build/LaunchPad.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> [2/4] Assembling macOS .app bundle at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
rm -rf "$PROJECT_DIR/build/LaunchOS.app"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/LaunchOS"
chmod +x "$MACOS_DIR/LaunchOS"

# Copy non-code icon/sound assets if original app is present for visual fidelity
if [ -d "/Applications/LaunchOS.app/Contents/Resources" ]; then
    for asset in Assets.car Glass.ogg; do
        if [ -f "/Applications/LaunchOS.app/Contents/Resources/$asset" ]; then
            cp "/Applications/LaunchOS.app/Contents/Resources/$asset" "$RESOURCES_DIR/"
        fi
    done
fi

# Prefer custom icns in project directory if present
if [ -f "$PROJECT_DIR/Launchpad-Light.icns" ]; then
    echo "==> Using local Launchpad-Light.icns as AppIcon..."
    cp "$PROJECT_DIR/Launchpad-Light.icns" "$RESOURCES_DIR/AppIcon.icns"
    cp "$PROJECT_DIR/Launchpad-Light.icns" "$RESOURCES_DIR/Launchpad-Light.icns"
elif [ -f "/Applications/LaunchOS.app/Contents/Resources/AppIcon.icns" ]; then
    cp "/Applications/LaunchOS.app/Contents/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

echo "==> [3/4] Writing Info.plist..."
cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>LaunchOS</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>app.launchos.replica</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>LaunchPad</string>
    <key>CFBundleDisplayName</key>
    <string>LaunchPad</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.4.2</string>
    <key>CFBundleVersion</key>
    <string>51</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>CFBundleURLName</key>
            <string>app.launchos.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>launchos</string>
            </array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>launchos</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>LaunchOS Backup File</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "==> [4/4] Signing $APP_BUNDLE (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Done! Built app bundle: $APP_BUNDLE"
