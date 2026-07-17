#!/bin/zsh
set -euo pipefail

repository_dir=${0:A:h:h}
mode=${1:---check}
legacy_label=${LEGACY_LAUNCH_AGENT_LABEL:-com.local.xiaomi-remote-hidutil}

if [[ "$mode" == "--check" ]]; then
  exec "$repository_dir/scripts/check-legacy-state.sh"
fi

if [[ "$mode" != "--apply" ]]; then
  echo "用法：$0 --check | --apply" >&2
  exit 2
fi

app_binary="$repository_dir/dist/XiaomiRemoteRemapper.app/Contents/MacOS/XiaomiRemoteRemapper"
if [[ ! -x "$app_binary" ]]; then
  echo "请先运行 scripts/check.sh，确认新程序可构建和自检。" >&2
  exit 3
fi
"$app_binary" --self-test

timestamp=$(/bin/date +%Y%m%d-%H%M%S)
backup_dir="$HOME/Library/Application Support/XiaomiRemoteRemapper/legacy-backup-$timestamp"
/bin/mkdir -p "$backup_dir"

launch_agent="$HOME/Library/LaunchAgents/$legacy_label.plist"
legacy_script="$HOME/.local/bin/xiaomi-remote-hidutil.sh"
karabiner_config="$HOME/.config/karabiner/karabiner.json"

[[ -f "$launch_agent" ]] && /bin/cp -p "$launch_agent" "$backup_dir/"
[[ -f "$legacy_script" ]] && /bin/cp -p "$legacy_script" "$backup_dir/"
[[ -f "$karabiner_config" ]] && /bin/cp -p "$karabiner_config" "$backup_dir/karabiner.json"

/bin/launchctl bootout "gui/$UID" "$launch_agent" 2>/dev/null || true
/usr/bin/hidutil property --matching '{"VendorID":10007,"ProductID":12984}' --set '{"UserKeyMapping":[]}'
/usr/bin/hidutil property --matching '{"VendorID":1452,"ProductID":591}' --set '{"UserKeyMapping":[]}'

echo "旧 LaunchAgent 已停止，两层 UserKeyMapping 已清空。"
echo "备份目录：$backup_dir"
echo "还需在 Karabiner-Elements → Devices 中关闭该遥控器的 Modify events。"
echo "确认后启动：open '$repository_dir/dist/XiaomiRemoteRemapper.app'"
