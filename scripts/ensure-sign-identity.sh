#!/bin/bash
# 一次性创建本地自签名代码签名证书，让 macOS 隐私授权（麦克风/摄像头等 TCC 权限）在重新构建后依然有效。
#
# 背景：ad-hoc 签名（codesign -s -）的 designated requirement 只有 cdhash，
# 重新构建后 cdhash 变了，TCC 就把新包当成另一个 app，已授权的麦克风被作废 → 每次启动都重新弹窗。
# 换成自签名证书后 requirement 变成 `identifier "com.membrow.app" and certificate leaf = H"..."`，跨构建稳定。
#
# 用法：scripts/ensure-sign-identity.sh [证书 CN]，默认 "Membrow Local Signing"
# 只需执行一次；macOS 会弹一次系统密码框（写入用户信任设置）。
set -euo pipefail

NAME="${1:-Membrow Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
    echo "签名身份已存在：$NAME"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# OpenSSL 3 要 -legacy 才能导出钥匙串可导入的 p12；系统自带 LibreSSL 默认就是旧格式。
P12_EXTRA=()
case "$(openssl version)" in
    OpenSSL\ 3*) P12_EXTRA+=(-legacy) ;;
esac
openssl pkcs12 -export "${P12_EXTRA[@]}" \
    -in "$TMP/cert.pem" -inkey "$TMP/key.pem" \
    -out "$TMP/id.p12" -password pass:membrow >/dev/null 2>&1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P membrow -T /usr/bin/codesign >/dev/null

# 不受信任的证书签出来的包，系统不认这个签名身份，TCC 依旧会每次失效。
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$TMP/cert.pem"

echo "已创建签名身份：$NAME"
