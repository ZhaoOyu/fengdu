#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app=dist/Fengdu.app
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
arch=$(lipo -archs "$app/Contents/MacOS/Fengdu")
name="Fengdu-${version}-macos-${arch}.dmg"
codesign --verify --deep --strict "$app"
mkdir -p build/release
stage=$(mktemp -d "$PWD/build/package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Fengdu.app"
ln -s /Applications "$stage/Applications"
hdiutil create -ov -volname "风度 Fengdu $version" -srcfolder "$stage" -format UDZO "build/release/$name"
hdiutil verify "build/release/$name"
(cd build/release && shasum -a 256 "$name" > SHA256SUMS.txt)
