#!/bin/zsh
set -euo pipefail

repository_dir=${0:A:h:h}
app_path="$repository_dir/dist/XiaomiRemoteRemapper.app"
dmg_path="$repository_dir/dist/XiaomiRemoteRemapper.dmg"

if [[ "${SKIP_APP_BUILD:-0}" != "1" ]]; then
  "$repository_dir/scripts/build-app.sh"
fi

if [[ ! -d "$app_path" ]]; then
  echo "未找到 App：$app_path" >&2
  exit 2
fi

staging_dir=$(/usr/bin/mktemp -d "/tmp/xiaomi-remote-dmg.XXXXXX")
cleanup() {
  /bin/rm -rf "$staging_dir"
}
trap cleanup EXIT

/usr/bin/ditto "$app_path" "$staging_dir/XiaomiRemoteRemapper.app"
/bin/cp "$repository_dir/LICENSE" "$staging_dir/LICENSE"
/bin/ln -s /Applications "$staging_dir/Applications"
/bin/rm -f "$dmg_path"
/usr/sbin/diskutil image create from \
  --volumeName "Xiaomi Remote Remapper" \
  --format UDZO \
  "$staging_dir" \
  "$dmg_path"

if [[ -n "${SIGN_IDENTITY:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp "$dmg_path"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${SIGN_IDENTITY:-}" || "${SIGN_IDENTITY}" == "-" ]]; then
    echo "使用 NOTARY_PROFILE 时必须同时提供 Developer ID SIGN_IDENTITY。" >&2
    exit 3
  fi
  /usr/bin/xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  /usr/bin/xcrun stapler staple "$dmg_path"
  /usr/bin/xcrun stapler validate "$dmg_path"
fi

(
  cd "${dmg_path:h}"
  /usr/bin/shasum -a 256 "${dmg_path:t}"
) > "$dmg_path.sha256"
echo "$dmg_path"
