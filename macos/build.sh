#!/bin/bash
# 編譯並打包成 VeyraMac.app(只需要 Xcode Command Line Tools);  ./build.sh install 會複製到 /Applications
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/VeyraMac.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VeyraMac "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns Resources/gamepad-shim.js "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Veyra for macOS</string>
  <key>CFBundleDisplayName</key><string>Veyra</string>
  <key>CFBundleExecutable</key><string>VeyraMac</string>
  <key>CFBundleIdentifier</key><string>local.veyramac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>用於讀取攝影機或 UVC 採集卡的畫面並即時增強(僅在本機處理)</string>
  <key>NSScreenCaptureUsageDescription</key><string>擷取螢幕或視窗畫面以進行即時增強(僅在本機處理)</string>
  <key>NSMicrophoneUsageDescription</key><string>Xbox 語音聊天需要使用麥克風</string>
  <key>NSLocalNetworkUsageDescription</key><string>連線到區域網路中的 Xbox</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
# 固定 designated requirement,讓重新編譯後的系統授權(螢幕錄製、相機)不會失效
codesign --force --sign - --requirements '=designated => identifier "local.veyramac"' "$APP"
echo "完成: $PWD/$APP"
if [ "$1" = "install" ]; then rm -rf /Applications/VeyraMac.app; cp -R "$APP" /Applications/; echo "已安裝到 /Applications/VeyraMac.app"; fi
