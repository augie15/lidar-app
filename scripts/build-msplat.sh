#!/bin/bash
# Rebuilds the vendored msplat trainer (Vendor/Msplat) from source at a pinned commit.
#
# msplat-ios (Apache-2.0) trains Gaussian splats on the iPhone with Metal compute shaders. Its own Package.swift
# downloads a prebuilt binary; Tilda builds the library itself from the reviewed source instead and keeps only the
# iOS device and simulator slices.
#
# Needs Xcode with the Metal Toolchain (xcodebuild -downloadComponent MetalToolchain) and CMake (brew install cmake).
# Usage: scripts/build-msplat.sh
set -euo pipefail

REPO="https://github.com/Plinth-it/msplat-ios.git"
COMMIT="8915af0e56095b7d9c636399c565aaeb3a161b0b"   # 2026-11-14, VERSION 3.0.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/Msplat"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet "$REPO" "$WORK/src"
git -C "$WORK/src" checkout --quiet "$COMMIT"
cd "$WORK/src"
find . -name '*.metallib' -not -path './.git/*' -delete   # never ship the repo's prebuilt shader libraries

IOS_DEPLOYMENT_TARGET=18.0 ./scripts/build-xcframework.sh

rm -rf "$DEST/MsplatCore.xcframework" "$DEST/Sources/Msplat"
mkdir -p "$DEST/Sources/Msplat/Resources"
xcodebuild -create-xcframework \
    -library build/ios-device/libmsplat_core.a    -headers build/xcf-headers \
    -library build/ios-simulator/libmsplat_core.a -headers build/xcf-headers \
    -output "$DEST/MsplatCore.xcframework"
cp swift/Sources/Msplat/*.swift "$DEST/Sources/Msplat/"
cp build/ios-device/default.metallib    "$DEST/Sources/Msplat/Resources/default-ios.metallib"
cp build/ios-simulator/default.metallib "$DEST/Sources/Msplat/Resources/default-iossimulator.metallib"
cp LICENSE THIRD_PARTY_NOTICES.md "$DEST/"
printf '%s\n' "$COMMIT" > "$DEST/COMMIT"
echo "Vendored msplat-ios $COMMIT into $DEST"
