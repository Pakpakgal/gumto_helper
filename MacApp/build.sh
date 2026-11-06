#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h}
PROJECT_DIR=${ROOT_DIR:h}
BUILD_DIR="$PROJECT_DIR/dist"
APP_NAME="영상 검수 도우미"
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
COMMON=(-swift-version 5 -parse-as-library -O -sdk "$SDK" -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework Vision -framework CoreImage -framework ImageIO -framework UniformTypeIdentifiers)

swiftc "${COMMON[@]}" -target arm64-apple-macos13.0 "${SOURCES[@]}" -o "$BUILD_DIR/MaeMook-arm64"
swiftc "${COMMON[@]}" -target x86_64-apple-macos13.0 "${SOURCES[@]}" -o "$BUILD_DIR/MaeMook-x86_64"
lipo -create "$BUILD_DIR/MaeMook-arm64" "$BUILD_DIR/MaeMook-x86_64" -output "$CONTENTS/MacOS/MaeMook"

cp "$ROOT_DIR/Info.plist" "$CONTENTS/Info.plist"
# 서명: 기본은 ad-hoc(다른 Mac에서는 Gatekeeper 경고가 뜸).
# Apple Developer ID 인증서가 있으면 SIGN_IDENTITY="Developer ID Application: 이름 (TEAMID)" 로 지정하고,
# 공증까지 하려면 NOTARY_PROFILE=<xcrun notarytool store-credentials 로 저장한 프로필 이름> 도 지정한다.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  codesign --force --deep --sign - "$APP_DIR"
fi

DMG_ROOT="$BUILD_DIR/dmg-root"
mkdir -p "$DMG_ROOT"
cp -R "$APP_DIR" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications" 2>/dev/null || true
# 인증서 없이 배포할 때 다른 Mac에서 처음 여는 방법을 DMG에 함께 넣는다.
cat > "$DMG_ROOT/처음 실행 안내.txt" <<'EOF_GUIDE'
[영상 검수 도우미 - 다른 Mac에서 처음 실행할 때]

1. "영상 검수 도우미.app"을 "Applications" 폴더로 끌어다 놓습니다.
2. "설치 도우미.command"를 더블클릭하면 보안 표시를 제거하고 앱을 실행합니다.
   (막히면 아래 3번의 터미널 명령을 직접 실행하세요.)
3. 터미널에서:
   xattr -dr com.apple.quarantine "/Applications/영상 검수 도우미.app"
4. 그래도 "확인되지 않은 개발자" 창이 뜨면
   시스템 설정 > 개인정보 보호 및 보안 > 아래쪽 "그래도 열기"를 누릅니다.

macOS 13 (Ventura) 이상에서 실행됩니다.
EOF_GUIDE
cat > "$DMG_ROOT/설치 도우미.command" <<'EOF_CMD'
#!/bin/zsh
DIR=${0:A:h}
APP="영상 검수 도우미.app"
if [ -d "$DIR/$APP" ]; then
  rm -rf "/Applications/$APP"
  cp -R "$DIR/$APP" /Applications/
fi
xattr -dr com.apple.quarantine "/Applications/$APP" 2>/dev/null
open "/Applications/$APP"
EOF_CMD
chmod +x "$DMG_ROOT/설치 도우미.command"

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
