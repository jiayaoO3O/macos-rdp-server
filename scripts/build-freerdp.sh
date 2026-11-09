#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
version=3.32.2
sha256=e95a505c0057e4d06a3b120477c421028769deba4db9c639ef3465d050f0955c
archive=".deps/downloads/freerdp-$version.tar.gz"
source=".deps/freerdp-$version"
build_dir="${FREERDP_BUILD_DIR:-.deps/build}"
install_prefix="${FREERDP_INSTALL_PREFIX:-$PWD/.deps/install}"
openssl_root="${OPENSSL_ROOT_DIR:-$(brew --prefix openssl@3)}"
mkdir -p .deps/downloads "$build_dir" "$install_prefix"
if [ ! -f "$archive" ]; then
 curl --fail --location --connect-timeout 20 --max-time 300 --retry 2 \
  "https://github.com/FreeRDP/FreeRDP/releases/download/$version/freerdp-$version.tar.gz" -o "$archive.tmp"
 mv "$archive.tmp" "$archive"
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
if [ "$actual" != "$sha256" ]; then
 echo 'FreeRDP archive checksum mismatch' >&2
 exit 1
fi
if [ ! -d "$source" ]; then tar -xzf "$archive" -C .deps; fi
cmake -S "$source" -B "$build_dir" \
 -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX="$install_prefix" \
 -DCMAKE_OSX_SYSROOT="${MACOSX_SDK_ROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
 -DWINPR_HAVE_PIPE2=OFF \
 -DOPENSSL_ROOT_DIR="$openssl_root" \
 -DWITH_OPUS=OFF \
 -DWITH_SERVER=ON -DWITH_SAMPLE=OFF -DWITH_CLIENT=OFF -DWITH_CLIENT_COMMON=ON \
 -DWITH_X11=OFF -DWITH_CHANNELS=ON -DWITH_PROXY=OFF -DWITH_PLATFORM_SERVER=OFF \
 -DCHANNEL_URBDRC=OFF \
 -DWITH_SHADOW=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF \
 -DWITH_WEBVIEW=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_MANPAGES=OFF \
 -DWITH_AAD=OFF -DWITH_KRB5=OFF -DWITH_PKCS11=OFF -DBUILD_TESTING=OFF \
 -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON
cmake --build "$build_dir" --parallel "${BUILD_JOBS:-6}"
cmake --install "$build_dir" --prefix "$install_prefix"
