#!/bin/zsh
set -euo pipefail

repository_dir=${0:A:h:h}
cd "$repository_dir"

/usr/bin/swift build
"$repository_dir/.build/debug/XiaomiRemoteRemapper" --self-test
"$repository_dir/scripts/build-app.sh"
SKIP_APP_BUILD=1 "$repository_dir/scripts/build-dmg.sh"
/usr/bin/plutil -lint "$repository_dir/Resources/Info.plist"
/bin/test -f "$repository_dir/dist/XiaomiRemoteRemapper.app/Contents/Resources/LICENSE"
/bin/test -f "$repository_dir/dist/XiaomiRemoteRemapper.app/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --verify --deep --strict "$repository_dir/dist/XiaomiRemoteRemapper.app"
/usr/bin/hdiutil verify "$repository_dir/dist/XiaomiRemoteRemapper.dmg"
/bin/test -s "$repository_dir/dist/XiaomiRemoteRemapper.dmg.sha256"
(
  cd "$repository_dir/dist"
  /usr/bin/shasum -a 256 -c XiaomiRemoteRemapper.dmg.sha256
)

echo "check_passed"
