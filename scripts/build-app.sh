#!/bin/bash
# 构建 Membrow.app（release 默认），并做 ad-hoc 签名。
# 用法：scripts/build-app.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="Membrow"
APP="$ROOT/dist/$APP_NAME.app"
VERSION="0.1.0"

cd "$ROOT"
# 本机只装了 CommandLineTools，ld 会报几条 search path not found（工具链默认路径不存在），
# 与项目无关；只过滤这一类，其余链接告警照常显示。`|| true` 只作用于 grep，编译失败仍由 pipefail 拦下。
quiet_ld() { grep -v -e 'ld: warning: directory not found for option' -e 'ld: warning: search path .* not found' || true; }
swift build -c "$CONFIG" 2>&1 | quiet_ld
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

RESOURCE_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
else
    echo "警告：未找到资源 bundle：$RESOURCE_BUNDLE" >&2
    exit 1
fi

cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.membrow.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Membrow</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Membrow 需要麦克风权限，以便在网页中进行语音通话、录音或语音输入。</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
        <key>NSAllowsArbitraryLoadsInWebContent</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" > /dev/null

# 签名身份：优先用本地自签名证书（跨构建稳定，TCC 授权不会被作废），找不到才回退 ad-hoc。
# ad-hoc 的 designated requirement 只有 cdhash，重新构建后 macOS 会把新包当成另一个 app，
# 已授权的麦克风等隐私权限失效，于是每次启动都重新弹窗。
SIGN_IDENTITY="${MEMBROW_SIGN_IDENTITY:-Membrow Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$SIGN_IDENTITY\""; then
    # 私钥访问可能被沙箱或锁定的登录钥匙串拒绝，codesign 会报 errSecInternalComponent；
    # 这时仍回退 ad-hoc，保证产物可用，但会把原因和后果明确打出来。
    if SIGN_OUTPUT="$(codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" 2>&1)"; then
        SIGN_NOTE="本地自签名（${SIGN_IDENTITY}）"
    else
        echo "警告：使用「${SIGN_IDENTITY}」签名失败：${SIGN_OUTPUT}" >&2
        if printf '%s' "$SIGN_OUTPUT" | grep -q "errSecInternalComponent"; then
            echo "      钥匙串拒绝访问签名私钥（常见于沙箱环境或锁屏的登录钥匙串）。" >&2
            echo "      请在普通终端重跑本脚本，或先执行 security unlock-keychain。" >&2
        fi
        echo "      本次回退 ad-hoc 以保证构建产物可用；ad-hoc 重建后系统授权（麦克风等）会失效。" >&2
        codesign --force --deep --sign - "$APP"
        SIGN_NOTE="ad-hoc（签名私钥不可访问，回退）"
    fi
else
    codesign --force --deep --sign - "$APP"
    SIGN_NOTE="ad-hoc（无开发者证书，未公证）"
    echo "警告：未找到签名身份「${SIGN_IDENTITY}」，已回退 ad-hoc。" >&2
    echo "      ad-hoc 签名每次重建都会让麦克风等系统授权失效（每次都重新弹窗）。" >&2
    echo "      一次性修复：./scripts/ensure-sign-identity.sh" >&2
fi
codesign --verify --deep --strict "$APP"

echo "已生成：$APP"
echo "签名：$SIGN_NOTE"
