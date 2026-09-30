#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product FXMic
app='build/EP2350 Voice.app'
mkdir -p "$app/Contents/MacOS"
cp .build/release/FXMic "$app/Contents/MacOS/FXMic"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.ep2350.voice</string>
<key>CFBundleName</key><string>EP2350 Voice</string>
<key>CFBundleExecutable</key><string>FXMic</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.3</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Observe EP-2350 handle markers locally. Optional developer mode transcribes speech.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Transcribe speech locally on this Mac.</string>
</dict></plist>
PLIST
# A Finder/File Provider flag on this generated bundle is rejected by codesign.
# Clear only that metadata; leave quarantine and all other extended attributes intact.
if xattr -p com.apple.FinderInfo "$app" >/dev/null 2>&1; then
    xattr -d com.apple.FinderInfo "$app"
fi
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'Built %s. This preview is ad-hoc signed, not notarized.\n' "$app"
