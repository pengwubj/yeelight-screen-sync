#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/dist/Yeelight Screen Sync.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build
BUILD_ARCHS=("$(uname -m)")
if [ "${UNIVERSAL:-0}" = 1 ]; then BUILD_ARCHS=(arm64 x86_64); fi
for BUILD_ARCH in "${BUILD_ARCHS[@]}"; do
    xcrun swiftc -O -swift-version 5 -parse-as-library -target "$BUILD_ARCH-apple-macos14.0" \
        -debug-prefix-map "$PWD"=. -file-prefix-map "$PWD"=. \
        App/*.swift -o ".build/YeelightControl-$BUILD_ARCH" \
        -framework SwiftUI -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo
done
if [ "${UNIVERSAL:-0}" = 1 ]; then
    lipo -create .build/YeelightControl-arm64 .build/YeelightControl-x86_64 -output .build/YeelightControl
else
    cp ".build/YeelightControl-${BUILD_ARCHS[0]}" .build/YeelightControl
fi
cp .build/YeelightControl "$APP/Contents/MacOS/YeelightControl.new"
mv -f "$APP/Contents/MacOS/YeelightControl.new" "$APP/Contents/MacOS/YeelightControl"
if [ ! -f .build/AppIcon.icns ] || [ scripts/MakeIcon.swift -nt .build/AppIcon.icns ]; then
    xcrun swift scripts/MakeIcon.swift .build/AppIcon.iconset
    iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>YeelightControl</string>
<key>CFBundleIdentifier</key><string>org.yeelight-screen-sync.app</string>
<key>CFBundleName</key><string>Yeelight Screen Sync</string>
<key>CFBundleDisplayName</key><string>Yeelight Screen Sync</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>在本机提取屏幕主色，让 Yeelight 氛围灯随画面变化。不会保存或上传画面。</string>
<key>NSLocalNetworkUsageDescription</key><string>发现并控制局域网中的 Yeelight 挂灯。</string>
</dict></plist>
PLIST
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier org.yeelight-screen-sync.app "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/YeelightControl" --self-test
printf 'Built: %s\n' "$APP"
