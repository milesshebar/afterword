#!/bin/bash
# Builds the release binary and wraps it into build/<APP_EXECUTABLE>.app (Command Line Tools only, no Xcode).
# Usage: scripts/bundle.sh [--open]
# MA_VERSION / MA_BUILD stamp CFBundleShortVersionString / CFBundleVersion (scripts/release-app.sh sets them; default 1.0 / 1).
# The name and bundle identifier come from scripts/product.env (BUNDLE_ID can be overridden from the environment).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/product.env

swift build -c release --product $APP_EXECUTABLE
BIN="$(swift build -c release --show-bin-path)/$APP_EXECUTABLE"

APP="build/$APP_EXECUTABLE.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_EXECUTABLE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_EXECUTABLE</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MA_VERSION:-1.0}</string>
    <key>CFBundleVersion</key><string>${MA_BUILD:-1}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSContactsUsageDescription</key>
    <string>$APP_NAME looks up names in your Contacts each time it shows a conversation, so old phone numbers read as people. Names are never copied into the archive.</string>
</dict>
</plist>
PLIST

# macOS ties the Contacts grant to the code signature. Ad-hoc signing ("-") changes with every build, so the
# approval is probably lost on each rebuild. Set SIGN_IDENTITY to a stable self-signed code-signing certificate
# (Keychain Access > Certificate Assistant > Create a Certificate, type Code Signing) to keep it.
# Only a named identity is used: never one picked from the keychain on its own.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
[ "$SIGN_IDENTITY" = "-" ] && echo "note: ad-hoc signing; the Contacts permission may need re-granting after each rebuild (see README.md)"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose=1 "$APP"
echo "built $APP"
[ "${1:-}" = "--open" ] && open "$APP"
exit 0
