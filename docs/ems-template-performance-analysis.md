# EMS 模板导入与查询性能分析

**2026-10-16 实现更新**：已在当前工作区完成连续地址默认合并、token 行索引、当前行按需编辑器、委托绘制趋势及趋势配置；下文原分析保留为修改前的基线，原文“仅分析/未修改业务代码”描述的是 2026-10-15 的状态。

在同一 WSL 环境、应用 System 主题及中文界面下，更新后的完整 EMS 会话测量为：

| 项目 | 修改前基线 | 修改后两次回放 |
| --- | ---: | ---: |
| SessionWidget.set_state | 9.48 s | 0.120–0.135 s |
| 加入标签页并首次显示 | 4.92 s | 0.061–0.069 s |
| 面板 QWidget 后代（包括内部控件） | 45,858 | 130 |
| 默认一轮查询请求数 | 1,832 | 44 |

单独的 RegistersPanel 加载约 82–122 ms；合并请求提交约 29–38 ms，一轮构造数据的响应分配与显示更新约 76–93 ms。两次回放仅供开发对照，并非统计基准；不包含物理通信，不能换算为 Windows 原生性能或真实设备往返速度。

EMS 模板设置 `registers_options.group_reads=true`、`trend_enabled=false`。新会话默认合并同一实际站号、同一类型的连续/重叠地址，不跨空洞；保存的 `group_reads=false` 保持有效。分组失败后退回单行，并在停止轮询或改变站号/连接前记住失败块。

类型、格式、枚举/位操作和删除按钮只在当前行创建。行配置保存在表格项及按 token 保存的设置中，查询和保存配置不依赖编辑器存在。排序和删除后维护 token 索引；高亮定时器按行复用，数量不再随变化次数增长。可见趋势直接绘制，只读取历史末尾最多 300 个值，避免复制整段历史。

在 Display… 的 Trend 列单独设置趋势，或右键选中行批量开启/关闭；“默认启用趋势”控制未设置覆盖值的行。模板/会话 JSON 允许 `registers_options.trend_enabled` 默认值及各行 `trend_enabled` 覆盖。旧配置缺少该字段时仍默认开启。关闭趋势会暂停历史采集、隐藏曲线，已有历史保留；查询、值显示、告警、表达式及文件日志照常工作。

上述数据来自 WSL；后续 Windows 安装验证见下文。真实 EMS 通信尚未验证；停止后取消 worker 已投递请求、日志批量刷新和完整 model/view 迁移不包含在本次实现中。

验证：32 个测试文件按独立进程执行，共 779 条功能断言通过；Ruff 与 `git diff --check` 通过。新增回归覆盖连续合并、站号归一、当前行编辑器数量、排序/删除后的响应定位、失败分组回退、趋势继承/覆盖及批量通知、高亮定时器复用。最后修改后另行复核相关测试。

进程退出仍有独立问题：部分 Qt 测试在所有断言通过后，于 Qt/PySide 的退出清理阶段偶发原生崩溃，因此全量进程检查尚未干净通过。原版代码、仅切换主题的最小脚本也能复现；PySide6 6.10.2 交叉验证仍出现退出异常。调试器栈落在 `QObject::~QObject` / `PySide::destroyQCoreApplication` / Python `atexit`，当前证据不足以确定根因。本次未将它作为已修复问题。

**2026-10-16 Windows 安装更新**

沿用原 Windows 构建环境（Python 3.12.6、PySide6 6.12.0、pymodbus 3.6.9、PyInstaller 6.22.3）完成打包，未升级运行依赖。11 个相关测试文件共 458 条功能断言通过。寄存器测试首次在 38 条断言通过后退出异常，再次执行完整文件正常退出；旧安装对应源码的对照测试也出现原生崩溃，该独立问题仍未解决。

从新 EXE 的 PYZ 中提取并对照验证了 35 个 GUI 模块的字节码，以及全部打包模板的 SHA-256。用提取的模块及包内 EMS 模板在 Windows 原生 Qt 平台回放：1,832 行加载约 87.65 ms，首次显示约 852.69 ms，一轮 44 个请求；值为构造数据，未连接实际设备。这不是整个 EXE 冷启动时间。

已更新 `C:\Users\acehe\AppData\Local\Programs\ModbusConnector` 并重新打开，主窗口存在且系统报告 Responding=true。旧安装保留为同级 `ModbusConnector.backup-20261016T013437Z`；正常关闭旧程序后备份了最新设置，替换和重新启动后的设置文件哈希一致。已有会话继续采用保存的设置；重新导入 EMS 模板可使用新的默认合并读取、关闭趋势配置。

安装及验证记录位于 `C:\Users\acehe\AppData\Local\Temp\modbus-connector-ems-perf-20261016T013010Z`，包含源码清单、测试日志、构建日志、包验证结果及部署结果。

---

日期：2026-10-15。分析基于当前工作区，HEAD 为 `a95c461`，包括工作区内尚未提交的「造梦者/EMS主控板 V2.0」模板。

现象：Windows 下导入和查询卡顿，未查询时操作正常。已在 WSL 的真实 Qt 表格加载、读取调度及结果处理路径复现主线程耗时；尚未进行 Windows 原生程序、真实串口及 EMS 设备测量。下面的秒数是本机诊断值，不能当作 Windows 实测值或优化后的交付承诺。本次仅分析，业务代码未改动。

**结论**

存在两类可独立解释现象的瓶颈：界面主线程处理大表格的成本，以及默认逐行读取造成的通信成本。另有查询高亮定时器累积和停止后请求继续执行的问题，会放大持续使用时的负担。

JSON 解析只有约 4～5 ms，不是主要耗时。Modbus 通信已经放在独立 QThread 中，不能通过单纯“把串口放到线程里”解决当前问题。

**模板规模与测量方法**

- 1,832 行、1,959 个寄存器，全部为 holding registers，默认全部参与查询。
- 624 行配置 value_names，293 行配置 bitmask。
- 默认 RTU 115200、8N1、unit 1、timeout 3 s，`group_reads=false`。
- 环境：WSL2、Python 3.12.12、PySide6 6.12.0、pymodbus 3.6.9、pyqtdarktheme 2.1.0；Qt offscreen 平台。
- 使用真实模板调用 RegistersPanel.set_state、read_all、handle_read_finished；结果回放使用构造值，绕过物理通信。时间不包含真实设备往返。
- 结果回放一次性处理一轮所有响应，用来衡量总 GUI 工作量。真实 RTU 响应会分散到达，因此不能将一轮处理总时间等同于每次查询都会连续冻结相同秒数。
- 以单次同步 GUI 调用超过 200 ms 作为诊断阈值。基线和临时优化版本均仍在加载检查中失败，说明还需要进一步优化。

**测量结果**

下表不启用 cProfile，各变体使用独立进程。加载前表格未显示，与 main_window._add_session 的实际顺序一致。数值为单次测量的近似值。

| 场景 | 加载表格 | 提交一轮查询 | 处理一轮响应 |
| --- | ---: | ---: | ---: |
| 最小 Qt 环境，原实现 | 3.08 s | 143 ms | 1.60 s |
| 最小 Qt 环境，仅替换 token 查找为索引 | 1.33 s | 137 ms | 82 ms |
| 最小 Qt 环境，仅预分配表格行 | 2.89 s | 138 ms | 1.58 s |
| 最小 Qt 环境，索引与预分配 | 1.27 s | 135 ms | 92 ms |
| 应用 System 主题、中文界面，原实现 | 9.53 s | 145 ms | 1.77 s |
| 应用 System 主题、中文界面，仅替换 token 查找 | 6.93 s | 144 ms | 96 ms |

另用真实 SessionWidget、应用 System 主题和中文界面测试：创建会话约 0.75 s，set_state 约 9.48 s，将会话加入标签页并首次显示约 4.92 s。后者包含 show/processEvents 的工作。

已显示表格再加载的测试约 12.9 s，首次布局/绘制另约 1.2 s；该场景与新建模板标签页不同。仅关闭 updatesEnabled 后加载仍约 12.5 s，表明关闭重绘不足以消除控件构建及查找成本。

这里的索引与预分配是临时诊断替换，适用于该脚本的顺序添加、无排序删除场景，并非可直接合入的完整实现。

**原因一：大表格使用大量常驻 QWidget**

位置：registers_panel.py 的 `_add_row`（约 990 行）、`_sync_value_names_combo`（约 2286 行）；main_window.py 的 `_add_session`（约 95 行）。

每行创建 Type/Format 下拉框、Trend 控件、删除按钮及其容器，枚举和位掩码行还创建 New value 编辑器。此模板共调用 setCellWidget 7,954 次；加载后的面板共有 45,858 个 QWidget 后代，包含下拉框内部控件，并不表示同等数量的原生窗口。

创建、布局、样式及首次显示都在 GUI 主线程。加载完成且数据不更新时无需反复执行这些操作，因此与“空闲不卡”一致。完整主题/中文场景明显慢于最小环境；当前实验未将主题、语言、字体分别隔离，不能精确归因于其中某一项。

改善：先让批量导入合并通知、缓存共享图标，并按时间预算分批构建，显示进度和取消入口。控件仍须在 GUI 线程操作，不能把 set_state 整体移到后台线程。预分配行和关闭重绘只能辅助改善。

主要结构优化是用 QStyledItemDelegate 绘制与按需创建编辑器，避免每行长期保留多个控件；Trend 改为绘制可见行。可先在 QTableWidget 上减少 cell widgets，再视收益迁移 QTableView + QAbstractTableModel。

Qt 官方也建议通过 delegate 实现动态内容和自定义编辑器：[QAbstractItemView.setIndexWidget](https://doc.qt.io/qtforpython-6/PySide6/QtWidgets/QAbstractItemView.html#PySide6.QtWidgets.QAbstractItemView.setIndexWidget)。

**原因二：token 定位产生平方级扫描**

位置：registers_panel.py 的 `_find_row_by_token`（1798 行）、`set_state`（892 行）、`_apply_read_values`（2691 行）。

`_find_row_by_token` 每次从头遍历表格。导入每行都调用它，一轮响应也每行调用它；1,832 行的一轮累计约 168 万次 token 访问。加载后的高亮清除还会重复定位。

隐藏表格的 cProfile 测量中，响应处理总计约 2.43 s，其中查找约 2.17 s，占约 90%。索引替换实验把完整主题场景的响应处理从约 1.77 s 降至 96 ms，说明这一项值得最先修复。

改善：维护 token 到行位置的索引；新增、删除、排序和移动时正确更新，或使用持久模型索引。为 `_pending_reads` 额外维护 pending token 集合，避免 `_read_pending` 每次扫描全部待处理请求及分组成员。必须保留分组回退、删除行后忽略响应及停止轮询的行为。

**原因三：逐行查询远超 1 s 默认轮询的通信预算**

位置：模板的 registers_options；registers_panel.py 的 `read_all`（2463 行）、`_poll_global_rows`（2474 行）、`_read_grouped`；models.py 的 `plan_grouped_reads`（369 行）。

当前一轮发送 1,832 个请求。按默认 115200、8N1，每字节 10 bit，以读取请求 8 字节、成功响应 5 + 2×count 字节计算：

| 读取方式 | 请求数 | 读取寄存器数（含合并空洞） | 仅字节传输的理论下限 |
| --- | ---: | ---: | ---: |
| 逐行 | 1,832 | 1,959 | 2.407 s |
| 连续地址合并，max_gap=0 | 44 | 1,959 | 0.390 s |
| 当前 Group reads 算法，max_gap=8 | 32 | 2,021 | 0.387 s |

这些下限不含 RTU 帧间隔、USB 延迟、设备处理、重试或超时。合并收益还来自减少设备处理与往返次数，实际数值须在 EMS 上确认。如果实际连接改成 TCP，上述串口下限不适用，但请求数量和 GUI 开销仍存在。

控件默认全局轮询间隔为 1,000 ms；全表逐行读取即使在理想串口条件下也无法每秒完成。代码已有“同一行未响应时不重复提交”的保护，不能据此宣称每秒无限新增 1,832 个请求；但首次仍会排入整张表，写操作和断开连接可能排在已有查询后面。

改善：提供 EMS 合法块范围及可配置合并间隙，优先 max_gap=0，确认 EMS 支持相应起址与长度后再启用。现有按钮使用 max_gap=8，会读取模板未列出的空洞；若设备拒绝，分组失败将退回逐行读取，收益可能消失。

轮询应采用有界请求队列，按实际完成速度调度，并对人工操作保留响应能力。按用途分开运行量、配置量、能效统计；常用运行量较快轮询，静态配置手动或低频读取。

**原因四：高亮定时器不释放，停止仅清除前端映射**

位置：registers_panel.py 的 `_flash_value_cell`（2722 行）、`_clear_flash`（2737 行）、`stop_polling`（约 2780 行）；session_widget.py 的 queued worker 连接。

每次显示值变化都会创建 parented、single-shot QTimer，但 timeout 后没有删除，也不复用，直到面板销毁才释放。100 行各变化三次的测量：QTimer 从 2 个增加到 302 个；等到全部过期后仍为 302 个，活跃数量为 0。累积的是对象，不是这些定时器一直触发。

改善：复用每行一个定时器，或由单个共享定时器维护变化截止时间；保留 generation 及告警颜色优先级。现有注释记录 Windows 上静态 singleShot(callable) 曾崩溃，不应简单换回该写法。

另用真实 ModbusWorker/QThread 和不接设备的延迟后端验证：排入 100 个查询后立即 stop_polling，前端 pending 变为 0，但后端仍执行全部 100 个请求。清除字典不能取消已经投递的 queued signal。

改善：由 worker 管理有界队列或为任务增加可取消的代次标识，停止时使尚未执行的旧任务失效；已经进行中的串口事务仍受其超时约束。重新启动时需防止旧任务影响新查询。

**次要开销与排除项**

- 每次 worker 读取至少产生两条普通日志、一条统计更新和一个结果信号；原始 TX/RX 另有信号。原始日志默认不显示，但仍格式化并保存；Log 按钮只切换面板可见性，也未停止日志收集。
- 简化日志回放中，每轮 1,832 笔交易对应普通日志 3,664 条、原始日志 3,664 条，append 约 217～270 ms；这是独立测量，不能直接与主表响应时间相加预测实际延迟。可采用环形缓冲、批量显示、统计限频及可选的流量采集。
- 普通查询不记录曲线历史，record 模式才追加；EMS 模板本身也没有 expressions。因此不能将 numpy、曲线历史或表达式重算作为本次默认场景的首要原因。
- backend 的串口已经设置 strict=False，处理 Windows inter-byte timeout 问题；本次没有证据将驱动或 USB 故障确定为主因。

**建议顺序与验收**

1. 优先建立行索引、pending token 集合，复用或释放高亮定时器。这些变更范围相对集中，查询更新收益已由对照实验支持。
2. 改善导入的主线程响应：批量通知、按时间预算分批创建；随后减少常驻 cell widgets。索引后加载仍有数秒，不能以“查询优化完成”代替导入问题解决。
3. 实现有界、可取消的读取调度；为 EMS 提供经过设备验证的连续块读取。
4. 批量刷新普通日志与统计；需要时再将整表迁移到 model/view。

现场立即缓解可先取消无关行的轮询勾选，保留当前关心的运行量；按实际吞吐增大轮询间隔，优先普通轮询模式。Filter 只隐藏行，不会减少查询数；切换 System/Light/Dark 都仍使用 qdarktheme，也不等同于关闭样式。

后续应在 Windows 打包程序上验证导入及首次显示、查询期间输入与滚动响应、查询/写入/停止/断开延迟，并持续观察变化数据下的内存及 QTimer 数量。建议将常规 GUI 处理切片控制在约 16～50 ms，避免持续超过 100 ms；这是优化验收目标，并非当前达到的指标。协议合并需在真实 EMS 上做只读验证，包括不支持地址、最大块长、超时及逐行回退。

**诊断产物**

诊断脚本与原始输出保存在本机 `/tmp/modbus-ems-performance/`，运行环境位于 `/tmp/modbus-ems-perf-venv/`，均为临时诊断目录。脚本内的替换逻辑未写入业务代码。

```bash
QT_QPA_PLATFORM=offscreen /tmp/modbus-ems-perf-venv/bin/python \
  /tmp/modbus-ems-performance/profile_ems.py --hidden --themed

QT_QPA_PLATFORM=offscreen /tmp/modbus-ems-perf-venv/bin/python \
  /tmp/modbus-ems-performance/profile_ems.py --hidden --themed --variant index

QT_QPA_PLATFORM=offscreen /tmp/modbus-ems-perf-venv/bin/python \
  /tmp/modbus-ems-performance/timers_queue.py
```

前两个命令因加载超出 200 ms 阈值返回 AssertionError，属于本次性能问题的预期复现结果，不表示功能测试通过。业务代码未更改，因此未运行完整功能测试套件；临时索引实现也未验证排序、移动和删除等完整交互。
