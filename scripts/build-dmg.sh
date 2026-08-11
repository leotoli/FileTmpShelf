#!/usr/bin/env bash
#
# build-dmg.sh — FileTmpShelf Release 打包脚本
#  1. Release 构建（arm64）
#  2. ditto 打包 .app → 拖拽安装 dmg（hdiutil create）
#  3. codesign --options runtime（可选，需 Developer ID 证书）
#  4. notarytool submit + stapler（可选，需公证凭据）
#
# 未配置证书/凭据时打印提示并继续，不会失败退出。
#
# 用法：
#   ./scripts/build-dmg.sh
#   SIGN_IDENTITY="Developer ID Application: Name (XXXXXX)" ./scripts/build-dmg.sh
#   NOTARY_APPLE_ID="you@example.com" NOTARY_TEAM_ID="XXXXXX" NOTARY_PASSWORD="xxxx" ./scripts/build-dmg.sh
#
# 环境变量：
#   SIGN_IDENTITY     Developer ID 证书名（为空则跳过签名）
#   NOTARY_APPLE_ID   Apple ID（用于 notarytool）
#   NOTARY_TEAM_ID    Team ID（用于 notarytool）
#   NOTARY_PASSWORD   App 专用密码（用于 notarytool）
#   CONFIGURATION     构建配置（默认 Release）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="FileTmpShelf"
CONFIGURATION="${CONFIGURATION:-Release}"
XCODEPROJ="$ROOT_DIR/FileTmpShelf/$APP_NAME.xcodeproj"
DERIVED_DATA="$ROOT_DIR/FileTmpShelf/build/DerivedData"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/staging"
APP_BUILT="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

echo "==> [1/4] Release 构建（${CONFIGURATION}）..."
xcodebuild \
  -project "$XCODEPROJ" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  build

if [[ ! -d "$APP_BUILT" ]]; then
  echo "错误：构建产物未找到：$APP_BUILT" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUILT/Contents/Info.plist" 2>/dev/null || echo "0.1.0")"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "==> [2/4] 打包 .app（ditto → 拖拽安装布局）..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$APP_BUILT" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

sign_app() {
  local app="$1"
  echo "==> [签名] 使用证书：$SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
  echo "==> [签名] 验证："
  codesign --verify --deep --strict --verbose=2 "$app"
}

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  sign_app "$STAGING_DIR/$APP_NAME.app"
else
  echo "==> [签名] 未配置 Developer ID（设置环境变量 SIGN_IDENTITY），跳过签名。"
  echo "    前置条件：Apple Developer 账号申请 Developer ID Application 证书，并在 Keychain 中可用。"
fi

echo "==> [3/4] 创建 dmg..."
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DMG_PATH"
echo "==> [3/4] dmg 已生成：$DMG_PATH"

notarize_and_staple() {
  local dmg="$1"
  echo "==> [公证] 提交 notarytool..."
  xcrun notarytool submit "$dmg" \
    --apple-id "$NOTARY_APPLE_ID" \
    --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_PASSWORD" \
    --wait
  echo "==> [公证] stapler 打票..."
  xcrun stapler staple "$dmg"
  echo "==> [公证] 校验："
  xcrun stapler validate "$dmg"
}

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "==> [公证] 未配置 Developer ID 签名，跳过公证（未公证，可本地安装，首次启动有 Gatekeeper 提示）。"
  echo "    启用步骤：先配置 SIGN_IDENTITY 完成签名，再设置 NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD。"
elif [[ -z "${NOTARY_APPLE_ID:-}" || -z "${NOTARY_TEAM_ID:-}" || -z "${NOTARY_PASSWORD:-}" ]]; then
  echo "==> [公证] 已签名但缺少公证凭据（NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD），跳过公证。"
  echo "    前置条件：在 appleid.apple.com 生成 App 专用密码（"$APP_NAME" notarytool），并确认 Team ID。"
else
  notarize_and_staple "$DMG_PATH"
fi

echo ""
echo "✅ 完成。产物："
echo "   $DMG_PATH"
echo "   （未签名/未公证时可先用 hdiutil attach 验证挂载 + 拖拽安装。）"
