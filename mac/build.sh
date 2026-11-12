#!/bin/bash
# 编译并打包 PhoneBridge.app（菜单栏常驻，不占 Dock）
set -e
cd "$(dirname "$0")"

echo "▸ 编译…"
swift build -c release

APP="PhoneBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/PhoneBridge" "$APP/Contents/MacOS/PhoneBridge"
[ -f ../assets/AppIcon.icns ] && cp ../assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PhoneBridge</string>
  <key>CFBundleIdentifier</key><string>local.phonebridge</string>
  <key>CFBundleName</key><string>PhoneBridge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>PhoneBridge 通过蓝牙接收手机通知，不经过任何服务器。</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
DEST="$HOME/Applications/PhoneBridge.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "▸ 完成: $(pwd)/$APP"
echo "▸ 已安装: $DEST"
