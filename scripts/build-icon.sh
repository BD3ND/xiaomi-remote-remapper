#!/bin/zsh
set -euo pipefail

repository_dir=${0:A:h:h}
source_svg="$repository_dir/Resources/AppIcon.svg"
output_path=${1:-"$repository_dir/dist/AppIcon.icns"}
temporary_dir=$(/usr/bin/mktemp -d "/tmp/xiaomi-remote-icon.XXXXXX")

cleanup() {
  /bin/rm -rf "$temporary_dir"
}
trap cleanup EXIT

iconset="$temporary_dir/AppIcon.iconset"
master_png="$temporary_dir/AppIcon-1024.png"
/bin/mkdir -p "$iconset" "${output_path:h}"

/usr/bin/sips -s format png "$source_svg" --out "$master_png" >/dev/null

for specification in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size=${specification%% *}
  filename=${specification#* }
  /usr/bin/sips -z "$size" "$size" "$master_png" --out "$iconset/$filename" >/dev/null
done

/usr/bin/iconutil -c icns "$iconset" -o "$output_path"
echo "$output_path"
