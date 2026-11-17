#!/bin/bash
# 把构建产物 Membrow.app 安装到 /Applications。
# 用法：./install-app.sh            用现有 dist/Membrow.app
#      ./install-app.sh release     先重新构建再安装（debug|release）
# 只替换 app 包本身，不触碰数据目录 ~/Library/Application Support/com.membrow.app。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/dist/Membrow.app"
TARGET="/Applications/Membrow.app"

if [ $# -gt 0 ]; then
    "$ROOT/scripts/build-app.sh" "$1"
elif [ ! -d "$SRC" ]; then
    echo "未找到 $SRC，先构建…"
    "$ROOT/scripts/build-app.sh" release
fi

# 运行中的实例会占用包内文件，也不该在没有提示的情况下被杀掉
if pgrep -x Membrow > /dev/null; then
    echo "Membrow 正在运行，请先退出后再安装。" >&2
    exit 1
fi

if [ ! -w "/Applications" ]; then
    echo "/Applications 当前用户不可写，请用：sudo $0 $*" >&2
    exit 1
fi

rm -rf "$TARGET"
ditto "$SRC" "$TARGET"
codesign --verify --strict "$TARGET"

echo "已安装：$TARGET"
echo "若 Dock 仍显示旧图标/旧版本，是图标缓存问题：killall Dock"
