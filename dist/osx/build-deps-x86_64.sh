#!/usr/bin/env bash

set -euo pipefail

# Builds FFmpeg and wxWidgets from source for x86_64, natively cross-compiled
# via clang's -arch flag (no Rosetta, no Homebrew: Homebrew dropped Intel
# macOS bottles for both, see the note in release.yml). Only the libraries
# Spek actually needs: a decode-only FFmpeg (no external codec libs required,
# every format Spek's own tests decode has a built-in FFmpeg decoder) and a
# static wxWidgets.
#
# Idempotent: skips a dependency that's already built, so CI can cache
# PREFIX across runs instead of rebuilding every time.
#
# Requires nasm on PATH (FFmpeg's x86 SIMD assembly) and Xcode's clang.

FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=ee80a25a5621df84498cef46917be87eab3b4f01951e85c2c7cbe5c94914ee70
WX_VERSION=3.3.3
WX_SHA256=81b09d6dd9f1ed9301f8c55a968a488d0491f264dc2bab19a7e407ac67009482

PREFIX=$(cd "$(dirname "$0")/../.." && pwd)/deps-x86_64
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

CC="clang -arch x86_64"
CXX="clang++ -arch x86_64"

if [ -f "$PREFIX/lib/pkgconfig/libavcodec.pc" ]; then
    echo "FFmpeg already built, skipping."
else
    echo "Building FFmpeg $FFMPEG_VERSION for x86_64..."
    curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.bz2" -o "$BUILD_DIR/ffmpeg.tar.bz2"
    echo "$FFMPEG_SHA256  $BUILD_DIR/ffmpeg.tar.bz2" | shasum -a 256 -c -
    tar xjf "$BUILD_DIR/ffmpeg.tar.bz2" -C "$BUILD_DIR"
    (
        cd "$BUILD_DIR/ffmpeg-$FFMPEG_VERSION"
        ./configure \
            --prefix="$PREFIX" \
            --arch=x86_64 \
            --cc="$CC" \
            --cxx="$CXX" \
            --enable-cross-compile \
            --target-os=darwin \
            --disable-programs \
            --disable-doc \
            --disable-avdevice \
            --disable-swscale \
            --disable-avfilter \
            --disable-encoders \
            --disable-muxers \
            --disable-devices \
            --disable-filters \
            --disable-network
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )
fi

if [ -f "$PREFIX/bin/wx-config" ]; then
    echo "wxWidgets already built, skipping."
else
    echo "Building wxWidgets $WX_VERSION for x86_64..."
    curl -fsSL "https://github.com/wxWidgets/wxWidgets/releases/download/v$WX_VERSION/wxWidgets-$WX_VERSION.tar.bz2" -o "$BUILD_DIR/wx.tar.bz2"
    echo "$WX_SHA256  $BUILD_DIR/wx.tar.bz2" | shasum -a 256 -c -
    tar xjf "$BUILD_DIR/wx.tar.bz2" -C "$BUILD_DIR"
    (
        cd "$BUILD_DIR/wxWidgets-$WX_VERSION"
        ./configure \
            --prefix="$PREFIX" \
            --host=x86_64-apple-darwin \
            CC="$CC" \
            CXX="$CXX" \
            --with-macosx-version-min=11.0 \
            --with-cocoa \
            --disable-shared
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )
    # wx-config's full-path entries for the core wx libraries (e.g.
    # libwx_baseu-3.3.a) omit the -x86_64-apple-darwin host suffix its own
    # build actually names them with, while its -l flags for the bundled
    # third-party libs (tiff, jpeg, ...) get it right. Symlink around the
    # mismatch rather than patch wx-config's generated script.
    cd "$PREFIX/lib"
    for f in libwx_*-x86_64-apple-darwin.a; do
        ln -sf "$f" "${f%-x86_64-apple-darwin.a}.a"
    done
fi
