# 小米蓝牙遥控器 2 Pro macOS 按键映射

这是一个原生 macOS 菜单栏程序，使用 `IOHIDManager` 读取小米蓝牙遥控器 2 Pro，不依赖 Karabiner 解释特殊 usage。

存在“保持原按键”的配置时，程序采用共享读取，并由程序自身调用系统 `hidutil`，仅将需要重映射的来源按键映射到 HID Reserved。若所有按键都需要映射，程序会先尝试独占读取；当前 macOS 拒绝键盘型 HID 独占时自动降级为共享读取。退出程序时会清空程序设置的抑制映射；旧 LaunchAgent 和 Karabiner 规则不再参与运行。

## 默认映射

| 遥控器输入 | HID usage | 输出动作 |
| --- | ---: | --- |
| 特殊键 | `7:241` | 删除键 |
| F5 | `7:62` | Fn 按下/松开 |
| Home | `7:74` | 保持原按键，不拦截 |
| Application | `7:101` | 将 Codex 调到前台，并按当前窗口尺寸点击输入区聚焦 |
| `` ` / ~ `` | `7:53` | 保持原按键，不拦截 |
| Power | `7:102` | macOS Power 系统事件重放 |

Power 需要特别说明：设备被独占后，原始 HID 报告不会再进入系统，因此这里是 `NX_SYSDEFINED/NX_POWER_KEY` 重放，并非字节级透传。真实机器测试前不要连续或长按 Power。

## 构建和启动

```bash
./scripts/check.sh
open dist/XiaomiRemoteRemapper.app
```

`check.sh` 会执行 debug/release 编译、12 项内置自检、App bundle 打包、签名和签名校验。生成物位于 `dist/XiaomiRemoteRemapper.app`。

仓库默认使用中性的 Bundle ID `io.github.xiaomi-remote-remapper`。如维护者已有稳定的本机 Bundle ID，可仅在构建命令中覆盖，不要把个人标识提交到仓库：

```bash
BUNDLE_IDENTIFIER=your.bundle.identifier ./scripts/check.sh
```

长期迭代时可创建仅保存在本机登录钥匙串中的代码签名身份。脚本不会把证书私钥写入仓库：

```bash
./scripts/create-local-signing-identity.sh
./scripts/check.sh
```

创建后，`build-app.sh` 会自动优先使用 `XiaomiRemoteRemapper Local Code Signing`，避免每次构建因 ad-hoc 哈希变化而重新创建权限身份。

可用应用本身的身份检查当前权限与序列号绑定：

```bash
dist/XiaomiRemoteRemapper.app/Contents/MacOS/XiaomiRemoteRemapper --diagnostics
```

需要以 App 自身身份重新登记两项权限时，可通过 LaunchServices 请求：

```bash
open -n dist/XiaomiRemoteRemapper.app --args --request-permissions
```

排查系统对管理器和单设备打开路径的差异：

```bash
open -n dist/XiaomiRemoteRemapper.app --args --probe-hid-open
```

安装到 `/Applications` 后可登记或取消登录启动：

```bash
open -n /Applications/XiaomiRemoteRemapper.app --args --enable-login-item
open -n /Applications/XiaomiRemoteRemapper.app --args --disable-login-item
```

从终端直接执行 `--diagnostics` 时，macOS 可能把终端或调用进程视为权限负责进程；最终应以正常启动后的菜单状态和日志中的 HID 打开结果为准。

程序首次运行后：

1. 在菜单栏无线电波图标中分别请求“输入监控”和“辅助功能”权限。
2. 打开“按键映射…”可查看、修改或恢复默认映射。
3. 第一次连接 VID `10007` / PID `12984` 的键盘接口时，程序保存设备序列号；之后 VID、PID、序列号共同参与匹配。
4. 权限或登录启动状态变化后，如菜单未立即刷新，可点“重新连接”。

配置保存在 `~/Library/Application Support/XiaomiRemoteRemapper/config.json`，日志保存在 `~/Library/Logs/XiaomiRemoteRemapper/app.log`。未配置的 usage 会完整记录在日志中。

## 从 Karabiner / hidutil 迁移

先保持旧方案不变，确认新 App 已通过构建和自检：

```bash
./scripts/migrate-legacy.sh --check
```

准备开始独占设备测试时再执行：

```bash
./scripts/migrate-legacy.sh --apply
```

该操作会先备份旧 LaunchAgent、旧脚本和 Karabiner 配置，然后停止旧 LaunchAgent，并清空物理遥控器与 Karabiner 虚拟键盘的两层 `UserKeyMapping`。旧标签可在运行时指定，例如 `LEGACY_LAUNCH_AGENT_LABEL=com.local.xiaomi-remote-hidutil ./scripts/migrate-legacy.sh --apply`。脚本不会自动改写 Karabiner JSON；请在 Karabiner-Elements 的 Devices 页面关闭该遥控器的 “Modify events”，再启动本程序。

## 真实设备验收清单

- `7:241` 每次只产生一次 Delete，原按键不再重复触发。
- F5 按住时，能与 MacBook 内置键盘的按键形成 Fn 组合；松开或蓝牙断开后不残留 Fn 状态。
- Home 和反引号不进入抑制映射，保持系统收到的原始行为。
- Application 唤起已安装的 `com.openai.codex`，并按窗口尺寸定位输入区获取焦点。
- Power 短按行为与未独占前一致；长按、重复 HID down 报告不会被重复重放。
- 蓝牙断开和重连后自动恢复，不需要退出程序。
- 睡眠/唤醒、锁屏、解锁、快速切换用户后，连接状态与权限状态正确。
- 遥控器原始输入和映射输出没有双触发。

设备不在线时只能完成构建、配置和生命周期路径验证；上述硬件行为必须在遥控器连接后逐项观察日志和实际系统响应。
