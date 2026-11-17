#!/bin/bash
# Build a Release copy of Frisket and package it as a drag-to-install disk image.
#
#   macos/scripts/make-dmg.sh
#
# Output: release/Frisket-<version>.dmg at the repository root (gitignored).
# The app is signed ad hoc, as the project is set up; to distribute it, sign with
# a Developer ID and notarise the disk image first.
set -euo pipefail

macos_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$macos_dir/.." && pwd)"
build_dir="$macos_dir/build"
out_dir="$repo_dir/release"

cd "$macos_dir"
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi

xcodebuild -project Frisket.xcodeproj -scheme Frisket -configuration Release \
  -derivedDataPath "$build_dir/DerivedData" -destination 'generic/platform=macOS' \
  build -quiet

app="$build_dir/DerivedData/Build/Products/Release/Frisket.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
codesign --verify --deep --strict "$app"

stage="$(mktemp -d "${TMPDIR:-/tmp}/frisket-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Frisket.app"
ln -s /Applications "$stage/Applications"

mkdir -p "$out_dir"
dmg="$out_dir/Frisket-$version.dmg"
hdiutil create -volname "Frisket $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
hdiutil verify "$dmg" >/dev/null

echo "$dmg"
