#!/bin/zsh
set -euo pipefail

repository_dir=${0:A:h:h}
cd "$repository_dir"

/usr/bin/swift build
"$repository_dir/.build/debug/XiaomiRemoteRemapper" --self-test
"$repository_dir/scripts/build-app.sh"
/usr/bin/plutil -lint "$repository_dir/Resources/Info.plist"
/usr/bin/codesign --verify --deep --strict "$repository_dir/dist/XiaomiRemoteRemapper.app"

echo "check_passed"
