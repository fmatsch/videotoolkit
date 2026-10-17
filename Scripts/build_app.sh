#!/bin/bash
# Baut "Video Toolkit.app" (Release, ad-hoc signiert, App-Sandbox ohne Netzwerk).
# Aufruf: Scripts/build_app.sh   → erzeugt ./build/Video Toolkit.app
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Video Toolkit.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VideoToolkit "$APP/Contents/MacOS/VideoToolkit"
cp -R Models "$APP/Contents/Resources/Models"
# Große optionale Modelle (Whisper, Demucs) nur einbetten, wenn sie vorhanden sind; für Veröffentlichungen: VT_NO_OPTIONAL=1
if [ "${VT_NO_OPTIONAL:-0}" = "1" ]; then rm -rf "$APP/Contents/Resources/Models/Optional"; fi
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift Scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - --entitlements Resources/VideoToolkit.entitlements "$APP"
echo "Fertig: $APP"
