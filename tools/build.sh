#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p build/module-cache dist/Fengdu.app/Contents/{MacOS,Resources}
architecture="$(uname -m)"
xcrun swiftc -swift-version 5 -O -target "$architecture-apple-macosx14.0" \
  -module-cache-path "$PWD/build/module-cache" Sources/*.swift \
  -framework AppKit -framework IOKit -o dist/Fengdu.app/Contents/MacOS/Fengdu
cp packaging/Info.plist dist/Fengdu.app/Contents/Info.plist
cp LICENSE THIRD_PARTY_NOTICES.md docs/Stats-LICENSE.txt dist/Fengdu.app/Contents/Resources/
codesign --force --deep --sign - dist/Fengdu.app
printf 'Built %s\n' "$PWD/dist/Fengdu.app"
