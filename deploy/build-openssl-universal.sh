#!/usr/bin/env bash
# Build universal (x86_64 + arm64) static OpenSSL for libdatachannel.
# Output: build-openssl-universal/{include,lib/libssl.a,lib/libcrypto.a}
# Idempotent: skips download if build/openssl-src exists.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$repo_root/build"
cd "$repo_root/build"
version="${OPENSSL_VERSION:-3.6.3}"

if [ ! -d openssl-src ]; then
  curl -L -f -o openssl.tar.gz \
    "https://github.com/openssl/openssl/releases/download/openssl-${version}/openssl-${version}.tar.gz" ||
    curl -L -f -o openssl.tar.gz "https://www.openssl.org/source/openssl-${version}.tar.gz"
  mkdir openssl-src && tar xzf openssl.tar.gz -C openssl-src --strip-components=1
fi

cd openssl-src
for arch in x86_64 arm64; do
  case $arch in
    x86_64) target=darwin64-x86_64-cc ;;
    arm64) target=darwin64-arm64-cc ;;
  esac
  ./Configure "$target" no-shared no-tests CFLAGS=-fPIC --prefix="$PWD/out-$arch"
  make -j4
  make install_sw
  make clean
done

mkdir -p ../openssl-universal/include ../openssl-universal/lib
cp -R out-x86_64/include/openssl ../openssl-universal/include/
for lib in libcrypto.a libssl.a; do
  lipo -create out-x86_64/lib/$lib out-arm64/lib/$lib \
    -output ../openssl-universal/lib/$lib
done
lipo -info ../openssl-universal/lib/libssl.a ../openssl-universal/lib/libcrypto.a
