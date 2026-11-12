#!/bin/zsh
# Builds Paint.app (그림판) into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Paint.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  *.swift -o "$APP/Contents/MacOS/Paint"

# App icon from Paint_logo.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift tools/make_icon.swift Paint_logo.png build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Paint</string>
  <key>CFBundleIdentifier</key><string>local.idontcare.paint</string>
  <key>CFBundleName</key><string>Paint</string>
  <key>CFBundleDisplayName</key><string>Paint</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Localized app name: "그림판" when macOS is in Korean (Finder, Spotlight, Dock, menu bar), "Paint" otherwise.
mkdir -p "$APP/Contents/Resources/ko.lproj" "$APP/Contents/Resources/en.lproj"
printf 'CFBundleName = "그림판";\nCFBundleDisplayName = "그림판";\n' > "$APP/Contents/Resources/ko.lproj/InfoPlist.strings"
printf 'CFBundleName = "Paint";\nCFBundleDisplayName = "Paint";\n' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"

codesign --force --sign - "$APP"
touch "$APP"
echo "Built $APP"
