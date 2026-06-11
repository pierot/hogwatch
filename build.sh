#!/bin/bash
# Builds Hogwatch.app — a minimal bundle is required because
# UNUserNotificationCenter refuses to run from a bare executable.
set -euo pipefail
cd "$(dirname "$0")"

APP="Hogwatch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>be.jackjoe.hogwatch</string>
	<key>CFBundleName</key>
	<string>Hogwatch</string>
	<key>CFBundleExecutable</key>
	<string>Hogwatch</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

cp AppIcon.icns "$APP/Contents/Resources/"

swiftc -O -target arm64-apple-macos13.0  -o "$APP/Contents/MacOS/Hogwatch.arm64"  main.swift
swiftc -O -target x86_64-apple-macos13.0 -o "$APP/Contents/MacOS/Hogwatch.x86_64" main.swift
lipo -create -output "$APP/Contents/MacOS/Hogwatch" \
    "$APP/Contents/MacOS/Hogwatch.arm64" "$APP/Contents/MacOS/Hogwatch.x86_64"
rm "$APP/Contents/MacOS/Hogwatch.arm64" "$APP/Contents/MacOS/Hogwatch.x86_64"
codesign --force -s - "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Hogwatch"))"
echo "Run:  open $APP"
