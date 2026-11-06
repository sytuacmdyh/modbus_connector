# macOS 功能验收报告

- 日期：2026-11-06
- 基线：`3061728` 加本次未提交的 macOS 适配；应用版本 0.16.9。
- 主机：macOS 14.8.9（23J631），Intel x86_64。未验收 Linux。
- 工具：Flutter 3.47.8 / Dart 3.13.7，Xcode 16.2（16C5032a），CocoaPods 1.16.2；Ruby 和 GNU autotools 安装在用户目录。
- 范围：Intel/Apple Silicon 双架构、本地构建、GitHub Releases 自动更新；不发布。本机无物理串口设备。
- 结论：**本地双架构构建、安装及基本 UI 验收通过；整体有条件通过，不能标记全部验收通过。** 大表格连续缩放性能未达标，独立图表窗口目视验收、在线完整升级、Apple Silicon 实机和物理串口仍待补。

## 本地产物与复现

已安装：`/Applications/Modbus Connector.app`，Release 应用约 50.2 MB。

DMG：`flutter_app/build/macos/modbus-connector-flutter-0.16.9-macos-universal.dmg`，约 22 MB。

SHA-256：`427cbaa0cdbc6f730323f578dca4e2de35e487ac0e090aaff3fa6cf2c5d479a3`；同目录有 `.sha256` 文件。未上传或发布。

本机激活与构建：

```bash
source /Users/dyh/.local/share/modbus-toolchain/env.sh
cd /Users/dyh/code/github/modbus_connector/flutter_app
bash tool/build_macos.sh
# DMG 打包；为避免覆盖既有产物，已存在相同版本 DMG 时脚本会拒绝覆盖
bash tool/package_macos.sh
```

环境文件设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。Xcode 安装包通过 Apple 签名验证；用户确认许可后完成首次启动。构建脚本检查首次启动状态，不仅检查版本输出。GUI 不包含 Python 运行时。

## 自动与原生检查

| 检查 | 结果及边界 |
| --- | --- |
| `flutter analyze --no-pub` | 通过，无问题。 |
| `flutter test --no-pub --reporter expanded` | 109 项全部通过，包含平台快捷键、连接、寄存器、筛选、工作区、图表等。属于组件/控制器证据。 |
| `dart test test_backend --reporter expanded` | 400 项通过、2 项跳过；不证明 Windows 安装或物理串口。 |
| Release 构建及打包 | 通过；5 个 Mach-O 全部含 arm64/x86_64，`codesign --verify --deep --strict` 通过。双架构构建不等于 Apple Silicon 实机验收。 |
| `desktop_test.dart`，macOS Profile | 通过，退出码 0；本地 TCP 演示、轮询、工程量写入、布尔写入、嵌入图表、断开重连。 |
| `parity_test.dart`，macOS Profile | 通过，退出码 0；独立会话、模拟器规则、主站采集、表达式、快照、CSV 日志、模板和状态。 |
| `templates_test.dart`，macOS Profile | 通过，退出码 0；使用隔离目录中 6 行/150 行本地验收模板，验证目录、完整行恢复及自定义模板。不是线上厂商目录验收。 |
| `performance_test.dart`，macOS Profile | **未通过，退出码 1**。248 行采集阶段 p90 构建 13.821 ms，通知 12 次；满历史滚动 p90 4.202 ms；连续缩放 p90 **18.602 ms**，超过现有 **16.7 ms** 门槛。未放宽门槛，尚未定位或修复。 |
| macOS 更新专项 | 9 项通过；临时双架构签名 C 应用的真实 DMG 机制测试，以及模拟签名/启动命令的交接回退测试。 |
| 真实产品 DMG 暂存 | 通过；直接调用产品 `stageMacUpdate`，将此次 Flutter DMG 只读挂载、验证标识/版本/签名/架构、复制并再次验证，随后卸载并清理暂存。未替换运行中的应用。 |

四个原生集成文件逐个运行，命令格式：

```bash
MODBUS_FLUTTER_HOME=/Users/dyh/.local/share/modbus-macos-acceptance/integration flutter drive --driver=test_driver/native_driver.dart   --target=integration_test/desktop_test.dart -d macos --profile
```

模板用例使用 `/Users/dyh/.local/share/modbus-macos-acceptance/templates`。驱动实际连接 VM Service 并返回测试结果。日志有 integration_test 原生插件未检测到的提示；前三个用例的驱动结果和退出码均成功，性能用例正确返回失败，没有将警告或构建成功当成测试成功。

## 安装后的实际 UI 操作

| 功能 | 实际观察 |
| --- | --- |
| 首次启动及布局 | 安装后的 Release 正常显示主窗口、连接栏、筛选栏和填满剩余高度的寄存器表，无启动崩溃；默认最小内容尺寸 900×650。未完成多显示器/DPI 全覆盖。 |
| 本地演示 | 新增独立演示页，6 行数据显示并持续变化，原有主站页保留。 |
| 轮询中写入 | 在轮询运行时将 Demo setpoint 从 10 写为 23.5 °C，显示正确，轮询继续。 |
| 筛选及选择 | 输入 setpoint 显示 1/6，清除后恢复 6/6；行选择显示浮动工具栏。 |
| 连接锁定 | 已连接时结构编辑禁用；断开停止采集并恢复编辑，重连成功。 |
| 趋势 | 断开后显式启用 Demo signal A 趋势，重连轮询后图表显示曲线样本与 min/max/mean。 |
| 原生文件对话框 | Export samples 打开 macOS Save 面板，导出 CSV 成功；检查文件含 timestamp/series/value 和真实采样值。 |
| 显式保存与重启 | Save workspace 写入隔离目录 settings.json；关闭后重启恢复两张会话页及 6 行演示寄存器，保持断开。 |
| 会话退出资源 | 关闭主窗口后主进程退出码 0，其图表子进程同时消失，未残留测试进程。 |
| 串口发现 | 刷新列出 `/dev/cu.BLTH` 和 `/dev/cu.Bluetooth-Incoming-Port`。只证明原生库加载及枚举，不证明 RTU 通信。 |
| 应用内更新检查 | 显示 Current 0.16.9 / Latest v0.16.7 / Up to date；与 GitHub API 相符。当前 release 无 macOS GUI DMG，未进行在线下载/安装。 |
| 独立图表 | 从主图表启动 `--graph-window` 子进程，诊断角色为 graph；另以受控样本管道启动真实 Release 查看器，收到 selected/settings 回传，关闭管道后退出码 0。但工具无法区分同 bundle ID 的多个进程窗口，未完成独立窗口的目视及交互验收。 |
| Command 快捷键 | 组件测试通过；本次原生键盘自动化未可靠验证组合键，保留实机操作待补，不把自动化无效输入直接认定为产品缺陷。 |

手工主流程使用 `MODBUS_FLUTTER_HOME=/Users/dyh/.local/share/modbus-macos-acceptance/manual`。未使用用户现有设备连接、WebDAV 凭据或物理串口。

## 缺口与未验收范围

1. **性能缺口**：满历史数据连续窗口缩放未达到既有 60 Hz 构建预算；详见性能测试数据。先记录，待统一确认后优化。
2. **macOS 菜单接入**：原生应用菜单 `Settings…` 为禁用状态，应用内齿轮仍是设置入口；是否接入原生菜单待对齐。
3. **在线升级端到端**：当前 [GitHub 最新发布 v0.16.7](https://github.com/sytuacmdyh/modbus_connector/releases/tag/v0.16.7) 无 macOS GUI DMG。真实新旧产品替换、重启、失败恢复仍需具备匹配资产后验收；本次不发布。
4. **独立图表窗口与快捷键**：已有进程/管道和组件测试证据，但原生目视与组合键操作尚未充分验证。
5. **硬件及扩展场景**：Apple Silicon 实机、物理 RTU、多个显示器/DPI、macOS 12 最低版本运行未验收。网关/被动监听/WebDAV 有后端测试，但未完成本轮原生 UI 逐项验收。
6. 本地 ad-hoc 签名满足本轮本地构建范围；未做 Developer ID 公证或对外分发 Gatekeeper 验收。

## 证据位置

完整日志和导出 CSV 已归档到本机 `/Users/dyh/.local/share/modbus-macos-acceptance/evidence/`，包含构建、静态/组件/后端测试、四项原生集成测试、真实 DMG 暂存、主窗口重启和图表管道日志。原始 `/tmp` 日志不作为唯一记录。

初次组件测试的地址预设时序断言已修正为独立采集时钟，完整重跑 109 项通过。新增性能失败未被隐藏或放宽。代码、缺口清单及本报告均尚未提交；待用户审阅后统一对齐后续缺口。
