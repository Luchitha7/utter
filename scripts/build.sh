#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Utter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -target "$(uname -m)-apple-macos14.0" -parse-as-library -swift-version 5 -O -framework AppKit -framework SwiftUI -framework AVFoundation -framework Speech -framework Carbon -framework EventKit "$ROOT/Sources/Utter.swift" -o "$APP/Contents/MacOS/Utter"
printf '%s' "$ROOT" > "$APP/Contents/Resources/workspace.txt"
cp "$ROOT/scripts/create-note.applescript" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Utter</string>
<key>CFBundleIdentifier</key><string>io.github.luchitha7.utter</string>
<key>CFBundleName</key><string>Utter</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Utter listens to your commands only when you start listening.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Utter turns your spoken commands into text to open apps and create notes.</string>
<key>NSAppleEventsUsageDescription</key><string>Utter creates a note in Notes when you ask it to.</string>
<key>NSRemindersFullAccessUsageDescription</key><string>Utter creates reminders when you ask it to.</string>
<key>NSRemindersUsageDescription</key><string>Utter creates reminders when you ask it to.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
printf 'Built: %s\n' "$APP"
