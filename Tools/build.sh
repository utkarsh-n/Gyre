#!/bin/zsh
# xcodebuild hangs loading projects from this iCloud-synced folder, so mirror the project
# to a local scratch directory and build there.
#   Tools/build.sh sim       → Debug build for the iPhone 17 Pro simulator
#   Tools/build.sh device    → Release build for a connected iPhone
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${GYRE_BUILD_DIR:-${TMPDIR:-/tmp}/GyreBuild}"
mkdir -p "$WORK"
rsync -a --delete --exclude 'Gyre.xcodeproj/xcuserdata' "$SRC/" "$WORK/src/"
cd "$WORK/src"
xcodegen generate --quiet
case "${1:-sim}" in
  sim)
    xcodebuild -project Gyre.xcodeproj -scheme Gyre -configuration Debug \
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath "$WORK/dd" build ;;
  device)
    xcodebuild -project Gyre.xcodeproj -scheme Gyre -configuration Release \
      -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath "$WORK/dd" build ;;
esac
