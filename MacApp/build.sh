#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h}
PROJECT_DIR=${ROOT_DIR:h}
BUILD_DIR="$PROJECT_DIR/dist"
APP_NAME="매묵 영상 검수 도우미"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
SDK=$(xcrun --sdk macosx --show-sdk-path)
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFT_MODULECACHE_PATH="$BUILD_DIR/ModuleCache"

mkdir -p "$BUILD_DIR" "$CONTENTS/MacOS" "$CONTENTS/Resources"

# bible.json을 앱 번들 리소스에 포함.
if [ -f "$ROOT_DIR/Resources/bible.json" ]; then
    cp "$ROOT_DIR/Resources/bible.json" "$CONTENTS/Resources/bible.json"
fi

xcrun actool "$ROOT_DIR/Assets.xcassets" \
  --compile "$CONTENTS/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$BUILD_DIR/asset-info.plist" >/dev/null

SOURCES=("$ROOT_DIR"/Sources/*.swift)
COMMON=(-swift-version 5 -parse-as-library -O -sdk "$SDK" -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework Vision -framework CoreImage -framework ImageIO -framework UniformTypeIdentifiers -framework UserNotifications)

swiftc "${COMMON[@]}" -target arm64-apple-macos13.0 "${SOURCES[@]}" -o "$BUILD_DIR/MaeMook-arm64"
swiftc "${COMMON[@]}" -target x86_64-apple-macos13.0 "${SOURCES[@]}" -o "$BUILD_DIR/MaeMook-x86_64"
lipo -create "$BUILD_DIR/MaeMook-arm64" "$BUILD_DIR/MaeMook-x86_64" -output "$CONTENTS/MacOS/MaeMook"

cp "$ROOT_DIR/Info.plist" "$CONTENTS/Info.plist"

# 피드백 토큰 파일이 있으면 번들에 주입(저장소에는 토큰을 넣지 않는다).
if [ -f "$HOME/.gumto_feedback_token" ]; then
  /usr/libexec/PlistBuddy -c "Set :MaeMookGitHubToken $(cat "$HOME/.gumto_feedback_token")" "$CONTENTS/Info.plist"
fi
# 서명: 기본은 ad-hoc(다른 Mac에서는 Gatekeeper 경고가 뜸).
# Apple Developer ID 인증서가 있으면 SIGN_IDENTITY="Developer ID Application: 이름 (TEAMID)" 로 지정하고,
# 공증까지 하려면 NOTARY_PROFILE=<xcrun notarytool store-credentials 로 저장한 프로필 이름> 도 지정한다.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  codesign --force --deep --sign - "$APP_DIR"
fi

DMG_ROOT="$BUILD_DIR/dmg-root"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP_DIR" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications" 2>/dev/null || true

hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$BUILD_DIR/$APP_NAME.dmg" >/dev/null

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$BUILD_DIR/$APP_NAME.dmg"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$BUILD_DIR/$APP_NAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$BUILD_DIR/$APP_NAME.dmg"
  fi
fi

echo "$APP_DIR"
echo "$BUILD_DIR/$APP_NAME.dmg"
