# Flutter 网页适配与验收

## 目标与使用方式

默认采用静态 Flutter Web，浏览器打开即可使用，不要求启动 Dart/Python 服务。
可选 Dart 服务补充浏览器无法提供的原生网络、远程串口及监听能力。
桌面版仍使用原有 isolate 和原生字节通道，不引入 Python 运行时。

| 功能 | 默认网页 | 配置 Dart 服务后 |
| --- | --- | --- |
| 寄存器/工作区编辑、CSV/JSON 导入导出 | 支持，文件上传/下载 | 支持 |
| 自定义模板与版本 | 当前站点 localStorage | 独立服务目录 |
| 本地演示、读写、轮询 | 内存演示，不开端口 | 服务端 TCP 演示 |
| RTU 串口 | Web Serial，显式选择并授权 | 服务端 libserialport |
| TCP、RTU over TCP/UDP | 浏览器不能直接使用原生套接字 | 支持 |
| 扫描器、Modbus 高级命令 | 在已连接的 Web Serial/演示上运行 | 在服务连接上运行 |
| 模拟器/被动抓包/透明网关 | 隐藏不可用模式 | 使用服务端资源 |
| 趋势、告警、快照、报文 | 页面内共享现有逻辑 | 同样保留 |
| 采样日志 | 内存 4 MiB，显式下载/分段 | 服务端 20 MiB/文件，显式下载 |
| 独立图表窗口 | 改为页面内图表 | 页面内图表 |
| 自动安装更新、WebDAV、云发布 | 首版隐藏 | 服务接口也不开放安装/云命令 |

## 实现结构

- `wire_protocol.dart`：纯 Dart 校验、TCP/RTU 帧与解析器。
- `wire_channel*`：原生 TCP/UDP/FFI 与浏览器 Web Serial 通道，事务共用
  `ModbusClient`。取消读和关闭等待资源释放，不自动重发写入。
- `register_operations.dart`：两端共用读写/分组/扫描/高级命令。
- `datastore.dart` / `memory_channel.dart`：浏览器内存演示，不需要监听端口。
- `bridge_local.dart`：页面内会话；`bridge_native.dart`：原有 isolate 会话；
  `remote/bridge.dart`：可选 WebSocket 会话。
- `settings_store`、`document_file`、图表宿主、诊断与更新通过条件导入隔离平台。
- `catalog_web.dart`：浏览器模板版本；`data_logger.dart`：共享采样/CSV/JSONL，
  `logger_buffer.dart` 提供有界内存段，桌面原生文件适配保持原来行为。
- `wide_integer.dart`：BigInt 与十进制有理数处理 UINT64/INT64 文本，避免 JS 的
  53 位有效整数限制。值格、复制、CSV 和采样日志使用准确文本；原始寄存器仍为
  16 位数值。趋势、表达式、数值告警仍是浮点运算，不能用来精确比较相邻大整数。

寄存器图仍是唯一读写表面，过滤只影响显示；轮询期间的写入等待活动读结束。
趋势仍须显式启用，原始值变化高亮三秒；页面内图表不另建连接。
日志下载排队等待当前读周期结束，保留轮询计时器，避免与活动读写争用会话。
后台计时器暂停后跳过遗漏轮询，不积压重放，并在明显暂停后记录采集间断。

## 静态部署

在 `flutter_app/` 运行 `flutter build web --release --no-web-resources-cdn`，部署完整 `build/web/`（包括 CanvasKit）到静态站点。
子目录部署指定 `--base-href /your-path/`。直接打开 `file://` 不是支持的部署方式。

Web Serial 需要受支持的浏览器、HTTPS/localhost 和一次用户选择授权。
不支持的浏览器仍可离线编辑、演示或连接可选服务。刷新后的旧串口标识不会授权设备，
必须重新选择；失败的连接不会静默切换到另一种传输。

工作区与模板按站点 origin 隔离，换域名/端口/浏览器配置会变成另一份存储。
关闭自动保存后仍需显式 Save；重要工作区应导出备份。文件导入上限 20 MiB。
页面关闭会终止默认模式采集并丢失未下载的日志；后台冻结、休眠不能承诺连续采样。

## 可选服务

`bin/modbus_service.dart` 是独立纯 Dart CLI；完整启动、TLS 和打包命令见
[`flutter_app/README.md`](../flutter_app/README.md#optional-dart-service)。

1. 在可访问设备的机器启动服务，提供匹配架构的 libserialport。
2. 使用 `--origin` 声明精确网页来源。默认仅监听 `127.0.0.1:18766`。
3. 网页 Settings → Optional Dart service 输入 `/ws` 地址与令牌，测试并应用。
   应用会等待关闭会话、停止日志，按现有工作区配置重新创建断开的标签。
4. 地址/令牌仅保存在本页内存，刷新恢复默认网页模式，不写入工作区或浏览器存储。
5. HTTPS 网页使用 TLS 反向代理提供 `wss://`；需转发 WebSocket Upgrade 与 Origin。
   本机网络权限仍由浏览器控制。

鉴权在首个 WebSocket 消息完成，令牌不进入 URL。协议协商版本及能力；每个连接拥有
独立 isolate 和设备资源，最多 64 个会话。读取消绕过命令队列；请求带序号，失联不重放
任何未确认写入。10 秒心跳，45 秒无消息清理会话；连接关闭等待后端资源释放。
不接受内部 worker、安装更新或云命令。日志文件限定在服务会话目录；下载不接受任意
宿主路径，会话关闭后删除其日志，须提前下载。模板单独持久保存。

`tool/package_service.dart` 生成当前 OS/架构的可执行文件、匹配的原生库、启动脚本与
LGPL notices。目标机不需要 Dart/Flutter/Python。Windows/Linux 的发行验收要分别执行，
不能由 macOS 的构建结果推断。

## 验收记录（2026-11-19）

- 完整 Flutter widget 测试：138 通过；最后工作区/设置/日志/设备面板/寄存器增量回归 39 通过；日志下载队列修正后的寄存器/日志回归 25 通过。
- 最新完整后端测试：447 通过、2 个浏览器专用文件在 VM 跳过。
- 新的 64 位边界、四字节序、缩放/舍入/限幅和 CSV 导出：VM + Chrome 共 18 通过。
- 浏览器日志容量、UTF-8、原子样本和停止后导出：VM + Chrome 共 2 通过。
- 可选服务 8 项集成测试通过：来源/鉴权、会话隔离、禁止路径/内部命令、日志下载、
  失联清理、取消读，以及 TCP、RTU-over-TCP 模拟器与透明网关、RTU-over-UDP 的
  实际网络读写。覆盖高级命令、关闭后释放监听端口、失联后拒绝写入，只有显式连接
  才新建会话；原生 CSV 日志回归也通过。
- 便携协议/内存演示：VM + Chrome 共 14 通过；Web Serial API 生命周期模拟 1 通过。
- Chrome 浏览器存储 2 通过；真实 LocalBridge 的 Flutter 浏览器 UI 测试 2 通过，覆盖演示采集、日志导出、显式保存/恢复、非原生模式导入提示，以及轮询中的日志导出队列。
- 最新 Release Web 构建通过（CanvasKit 从本站加载）；前一构建 Wasm 兼容性 dry run 通过。分析无问题。
- 已构建的静态网页手工验证内存演示轮询、轮询中写入 12.3 °C、刷新后标签断开恢复、
  自定义模板保存。可选服务真实浏览器鉴权/应用、服务端 TCP 演示轮询及写入 14.7 °C
  与 CSV 实际下载已通过，通信错误计数为 0。最后关闭 Dart 服务、刷新最新版静态网页，
  内存演示仍正常轮询，浏览器控制台无错误。最后一轮静态构建还实际下载了浏览器
  内存采样 CSV，关闭下载对话框后仍为 Polling、Errors 0。
- macOS 独立服务编译打包成功，使用打包的 libserialport 实际枚举串口成功。
  仅发现蓝牙虚拟端口，没有可供实测的 USB 串口设备。
- macOS 原生集成分别以 Profile 模式运行 `desktop_test.dart`、
  `register_workspace_test.dart`、`parity_test.dart`，三项均通过。覆盖多标签独立采集、
  图表、重连、原生 TCP 模拟器、过滤、轮询中写入、日志、模板与工作区保存。

本次软件验收已完成，按用户确认将实物串口验收安排在后续。物理串口授权、设备读写与
拔插尚未验收；Windows/Linux 原生服务发行及生产 TLS/局域网权限仍需对应环境验证。
以上记录区分浏览器模拟、实际本机网络、macOS 原生与实物硬件结果。
