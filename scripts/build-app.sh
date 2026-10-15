#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swift build -c release
bundle="$PWD/dist/OpenLaunch.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/OpenLaunch "$bundle/Contents/MacOS/OpenLaunch"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenLaunch</string>
<key>CFBundleIdentifier</key><string>local.openlaunch</string>
<key>CFBundleName</key><string>OpenLaunch</string>
<key>CFBundleDisplayName</key><string>OpenLaunch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.12</string>
<key>CFBundleVersion</key><string>17</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
if [[ -f resources/AppIcon.icns ]]; then cp resources/AppIcon.icns "$bundle/Contents/Resources/"; fi
codesign --force --sign - "$bundle"
print "$bundle"
