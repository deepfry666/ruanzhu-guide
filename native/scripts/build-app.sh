#!/bin/zsh
# 打 Release 包：native/dist/软件指南生成器.app（ad-hoc 签名）
# 用法：scripts/build-app.sh [--zip]
#   --zip   另外打一个 zip，方便拷到别的 Mac
set -euo pipefail
cd "${0:A:h}/.."

MAKE_ZIP=0
for arg in "$@"; do
  case $arg in
    --zip) MAKE_ZIP=1 ;;
    *) echo "未知参数：$arg"; exit 1 ;;
  esac
done

echo "==> 编译 Release"
xcodebuild -project ManualStudio.xcodeproj -scheme ManualStudio -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

SRC="build/DerivedData/Build/Products/Release/软件指南生成器.app"
[[ -d $SRC ]] || { echo "编译失败，没有找到 $SRC"; exit 1; }

OUT="dist/软件指南生成器.app"
rm -rf "$OUT"; mkdir -p dist
ditto "$SRC" "$OUT"
codesign --force --deep --sign - "$OUT"
codesign --verify --deep --strict "$OUT"
echo "==> 已生成 $OUT"

if (( MAKE_ZIP )); then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$OUT/Contents/Info.plist")
  ZIP="dist/软件指南生成器-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$OUT" "$ZIP"
  echo "==> 已生成 $ZIP"
fi
