#!/bin/zsh
set -euo pipefail

repository_dir=${0:A:h:h}
output_dir="$repository_dir/dist"
app_dir="$output_dir/XiaomiRemoteRemapper.app"
local_identity="XiaomiRemoteRemapper Local Code Signing"
bundle_identifier=${BUNDLE_IDENTIFIER:-io.gitee.bd3nd.xiaomi-remote-remapper}

cd "$repository_dir"
/usr/bin/swift build -c release

/bin/rm -rf "$app_dir"
/bin/mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
/bin/cp "$repository_dir/.build/release/XiaomiRemoteRemapper" "$app_dir/Contents/MacOS/XiaomiRemoteRemapper"
/bin/cp "$repository_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
/bin/cp "$repository_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
"$repository_dir/scripts/build-icon.sh" "$app_dir/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app_dir/Contents/Info.plist"
signing_identity=${SIGN_IDENTITY:-}
if [[ -z "$signing_identity" ]]; then
  if /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/grep -Fq "\"$local_identity\""; then
    signing_identity="$local_identity"
  else
    signing_identity="-"
  fi
fi

if [[ "$signing_identity" == "-" ]]; then
  /usr/bin/codesign --force --deep --sign - "$app_dir"
  echo "signing_identity=adhoc"
else
  if [[ "$signing_identity" == "$local_identity" ]]; then
    /usr/bin/codesign \
      --force \
      --deep \
      --options runtime \
      --timestamp=none \
      --sign "$signing_identity" \
      "$app_dir"
  else
    /usr/bin/codesign \
      --force \
      --deep \
      --options runtime \
      --timestamp \
      --sign "$signing_identity" \
      "$app_dir"
  fi
  echo "signing_identity=$signing_identity"
fi
/usr/bin/codesign --verify --deep --strict "$app_dir"

echo "bundle_identifier=$bundle_identifier"
echo "$app_dir"
