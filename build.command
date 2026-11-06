#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo 'Install Apple Command Line Tools: xcode-select --install, then run this script again.'
  exit 1
fi
APP="$PWD/build/Bred Animation Engine.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-macosx13.0" Sources/BredAnimationEngine.swift -o "$APP/Contents/MacOS/BredAnimationEngine" -framework AppKit -framework SwiftUI -framework ImageIO -framework UniformTypeIdentifiers -framework AVFoundation
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BredAnimationEngine</string>
<key>CFBundleIdentifier</key><string>pl.bredmc.animationengine</string>
<key>CFBundleName</key><string>Bred Animation Engine</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built: $APP"
open "$APP"
