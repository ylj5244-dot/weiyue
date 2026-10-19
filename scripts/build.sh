#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/微阅.app"
mkdir -p build/module-cache
WORK="$(mktemp -d "$ROOT/build/.app-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGED_APP="$WORK/微阅.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

# A release is universal by default. Restrict this only for local development:
# WEIYUE_ARCHS=arm64 bash scripts/build.sh
ARCHS=()
for arch in ${WEIYUE_ARCHS:-arm64 x86_64}; do
  case "$arch" in arm64|x86_64) ;; *) printf '不支持的构建架构：%s（可用 arm64、x86_64）\n' "$arch" >&2; exit 1 ;; esac
  for existing in "${ARCHS[@]:-}"; do
    if [ "$existing" = "$arch" ]; then printf '架构重复：%s\n' "$arch" >&2; exit 1; fi
  done
  ARCHS+=("$arch")
done
if [ "${#ARCHS[@]}" -eq 0 ]; then printf '请至少选择一种构建架构。\n' >&2; exit 1; fi

if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ] || [ scripts/package-icon.cjs -nt build/AppIcon.icns ]; then
  xcrun swiftc -module-cache-path build/module-cache scripts/make-icon.swift -o build/make-icon
  build/make-icon build/AppIcon.iconset
  node scripts/package-icon.cjs
fi
SOURCES=(Sources/Store.swift Sources/AIClient.swift Sources/DiscussionTitles.swift Sources/WebSearchClient.swift Sources/MediaPolicy.swift Sources/MediaStore.swift Sources/WorkspacePolicy.swift Sources/ReadingAppearance.swift Sources/ContentExtractor.swift Sources/DirectInput.swift Sources/CacheCleaner.swift Sources/AttachmentPreview.swift Sources/App.swift)
BINARIES=()
for arch in "${ARCHS[@]}"; do
  printf '正在构建 %s（macOS 14+）…\n' "$arch" >&2
  mkdir -p "build/module-cache/$arch"
  xcrun swiftc -module-cache-path "build/module-cache/$arch" -O -target "$arch-apple-macosx14.0" \
    "${SOURCES[@]}" \
    -framework CoreText -framework AppKit -framework WebKit -framework Security -framework Quartz -framework Vision -framework PDFKit -framework AVKit -framework AVFoundation -o "$WORK/WeiboReader-$arch"
  BINARIES+=("$WORK/WeiboReader-$arch")
done
if [ "${#BINARIES[@]}" -eq 1 ]; then
  cp "${BINARIES[0]}" "$STAGED_APP/Contents/MacOS/WeiboReader"
else
  xcrun lipo -create "${BINARIES[@]}" -output "$STAGED_APP/Contents/MacOS/WeiboReader"
fi
ditto --norsrc --noextattr Resources/ui "$STAGED_APP/Contents/Resources/ui"
ditto --norsrc --noextattr Resources/bridge "$STAGED_APP/Contents/Resources/bridge"
cp build/AppIcon.icns "$STAGED_APP/Contents/Resources/AppIcon.icns"
cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>微阅</string>
<key>CFBundleDisplayName</key><string>微阅</string>
<key>CFBundleIdentifier</key><string>local.weiyue.WeiboReader</string>
<key>CFBundleExecutable</key><string>WeiboReader</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.9</string>
<key>CFBundleVersion</key><string>15</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>个人本地阅读工具</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
<key>NSCameraUsageDescription</key><string>仅在你使用官方微博网页的视频功能时访问摄像头。</string>
<key>NSMicrophoneUsageDescription</key><string>仅在你使用官方微博网页的语音功能时访问麦克风。</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
for arch in "${ARCHS[@]}"; do
  xcrun lipo "$STAGED_APP/Contents/MacOS/WeiboReader" -verify_arch "$arch"
done
# Replace only the generated build after all compiles and signature checks pass.
if [ -e "$APP" ]; then mv "$APP" "$WORK/previous.app"; fi
if ! mv "$STAGED_APP" "$APP"; then
  if [ -e "$WORK/previous.app" ]; then mv "$WORK/previous.app" "$APP"; fi
  exit 1
fi
printf '%s\n' "$APP"
