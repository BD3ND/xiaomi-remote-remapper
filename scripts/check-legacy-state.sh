#!/bin/zsh
set -u

legacy_label=${LEGACY_LAUNCH_AGENT_LABEL:-com.local.xiaomi-remote-hidutil}

echo "LaunchAgent:"
/bin/launchctl print "gui/$UID/$legacy_label" 2>/dev/null | /usr/bin/head -n 12 || echo "未加载"

echo "物理遥控器 UserKeyMapping (10007/12984):"
/usr/bin/hidutil property --matching '{"VendorID":10007,"ProductID":12984}' --get UserKeyMapping 2>&1

echo "Karabiner 虚拟键盘 UserKeyMapping (1452/591):"
/usr/bin/hidutil property --matching '{"VendorID":1452,"ProductID":591}' --get UserKeyMapping 2>&1

echo "Karabiner 是否仍包含遥控器规则:"
/usr/bin/grep -nE '10007|12984' "$HOME/.config/karabiner/karabiner.json" 2>/dev/null || echo "未找到"
