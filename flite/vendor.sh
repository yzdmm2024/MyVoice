#!/bin/bash
# 交叉编译 Flite 2.x 为 iOS (arm64/arm64e) 静态库，供 我的语音 离线 TTS 使用。
# 在 CI (macos runner) 中运行；本机有 Xcode 工具链也可。
set -e

FLITE_VER=2.2
DEST="$(cd "$(dirname "$0")" && pwd)/build"
SYSROOT=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos --find clang)

echo "[vendor] sysroot = $SYSROOT"

if [ -f "$DEST/libflite.a" ]; then
  echo "[vendor] flite 已存在，跳过"
  exit 0
fi

cd "$(mktemp -d)"
curl -fSL "https://github.com/festvox/flite/archive/v${FLITE_VER}.tar.gz" -o flite.tgz
tar xzf flite.tgz
cd "flite-${FLITE_VER}"

# Flite 用 autoconf；这里只编一个英文音色减小体积
./configure \
  --prefix="$DEST" \
  --host=arm-apple-darwin \
  --with-audio=none \
  CC="$CC" \
  CFLAGS="-arch arm64 -arch arm64e -isysroot $SYSROOT -fembed-bitcode -miphoneos-version-min=14.0 -DNDEBUG" \
  LDFLAGS="-arch arm64 -arch arm64e -isysroot $SYSROOT"

make
make install

echo "[vendor] 产物：$DEST/libflite*.a"
ls -la "$DEST"
