#!/bin/sh
# Archive a Release build of Tilda and export it for App Store Connect.
set -eu

usage() {
  cat <<'USAGE'
Usage: scripts/archive.sh [options]

Generates the Xcode project, archives a Release build, then exports it for
App Store Connect using automatic signing.

Options:
  --bump         Increment CURRENT_PROJECT_VERSION in project.yml before archiving.
  --upload       Export with destination "upload": sends the build to App Store
                 Connect. Without this flag the export is written to build/export
                 (destination "export") and nothing is uploaded.
  --archive-only Stop after the archive step (no export, no upload).
  -h, --help     Show this help.

Needs:
  - xcodegen on PATH.
  - Config/Signing.local.xcconfig containing "DEVELOPMENT_TEAM = <team id>" (untracked).
  - Apple Distribution signing available to Xcode (Settings > Accounts).

Output:
  build/Tilda.xcarchive   the archive
  build/export/           the exported .ipa (export mode) or upload log
  build/ExportOptions.plist (generated; contains your team id, do not commit)
USAGE
}

BUMP=0
DEST=export
ARCHIVE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --bump) BUMP=1 ;;
    --upload) DEST=upload ;;
    --archive-only) ARCHIVE_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
ROOT=$(pwd)

command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found. Install it with: brew install xcodegen" >&2; exit 1; }

SIGNING=Config/Signing.local.xcconfig
[ -f "$SIGNING" ] || { echo "Missing $SIGNING. Create it with: printf 'DEVELOPMENT_TEAM = YOURTEAMID\\n' > $SIGNING" >&2; exit 1; }
TEAM_ID=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Za-z0-9]*\).*/\1/p' "$SIGNING" | head -n 1)
[ -n "$TEAM_ID" ] || { echo "No DEVELOPMENT_TEAM value found in $SIGNING" >&2; exit 1; }

if [ "$BUMP" -eq 1 ]; then
  CURRENT=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -n 1)
  [ -n "$CURRENT" ] || { echo "Could not read CURRENT_PROJECT_VERSION from project.yml" >&2; exit 1; }
  NEXT=$((CURRENT + 1))
  sed -i '' "s/^\([[:space:]]*CURRENT_PROJECT_VERSION:\).*/\1 \"$NEXT\"/" project.yml
  echo "Bumped CURRENT_PROJECT_VERSION: $CURRENT -> $NEXT"
fi

mkdir -p build
echo "==> xcodegen generate"
xcodegen generate -q

ARCHIVE=build/Tilda.xcarchive
rm -rf "$ARCHIVE"
echo "==> Archiving (Release)"
xcodebuild archive \
  -project Tilda.xcodeproj \
  -scheme Tilda \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates

if [ "$ARCHIVE_ONLY" -eq 1 ]; then
  echo "Archive written to $ARCHIVE (export skipped)."
  exit 0
fi

OPTIONS=build/ExportOptions.plist
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DEST</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

EXPORT=build/export
rm -rf "$EXPORT"
if [ "$DEST" = upload ]; then
  echo "==> Exporting and UPLOADING to App Store Connect"
else
  echo "==> Exporting to $EXPORT (no upload)"
fi
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS" \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates

echo "Done. Archive: $ROOT/$ARCHIVE"
[ "$DEST" = export ] && echo "IPA in: $ROOT/$EXPORT"
exit 0
