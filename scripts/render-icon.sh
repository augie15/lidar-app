#!/bin/sh
# Renders the 1024x1024 app icon from Tilda/Theme/TildaMark.swift (full bleed, opaque).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
cp "$ROOT/scripts/render-icon.swift" "$TMP/main.swift"
swiftc -o "$TMP/render" "$TMP/main.swift" "$ROOT/Tilda/Theme/TildaMark.swift" -parse-as-library 2>/dev/null || \
swiftc -o "$TMP/render" "$TMP/main.swift" "$ROOT/Tilda/Theme/TildaMark.swift"
"$TMP/render" "$ROOT/Tilda/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
rm -rf "$TMP"
