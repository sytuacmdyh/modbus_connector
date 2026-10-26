import 'package:flutter/material.dart';

import 'translations.dart';

const helpEnglish = {
  'Sessions': 'Use + to add an independent session. The mode menu switches between Master, Simulator, Sniffer and Gateway. Switching mode disconnects first. Closing a tab waits for its active transaction. Inactive tabs keep working.\n\nMaster supports TCP, serial RTU, RTU over TCP/UDP and a local TCP demo. Addresses are 0-based PDU addresses. Stop polling discards late results. Workspace → Local demo opens a separate tab with six example rows, connects and polls automatically. Signals move, the setpoint/counter/switch are writable, and reconnect resets demo values.',
  'Registers / CSV / snapshots': 'The Register map below the connection settings is the master read/write workspace. Add named rows manually or load a template, then use Read map or Poll map across units and areas. The table fills the available height. Connection settings opens a dialog; Apply saves valid edits and Cancel discards them. Activity lives on the right and can be hidden; narrow windows open it in a right drawer. Session tools opens traffic, logging, scanning and diagnostics. More tools expands graphs, expressions, grouping, CSV and snapshots. Drag headers to reorder columns and their edges to resize; click a header for movement/reset actions. Filter by name, zero-based address/range (decimal or 0x hex), polling status and function area; conditions combine. Address ranges include overlapping multi-register rows. The visible/total count and Clear filters show or restore the view. Filters do not restrict map reads/polling, CSV exports or snapshots. Changing filters clears selection; select-all and batch actions use visible rows, and movement skips hidden rows. Use the selection checkbox for batch actions; hold the left mouse button and sweep along that column to toggle each crossed row once. Drag to the top/bottom edge to auto-scroll. Use the floating bottom bar Enable polling / Disable polling buttons for selected rows, or the right-click menu; paused rows show a pause marker. Selection never changes polling settings. Tap a row to edit count, format, byte order, scale/offset, engineering units and value/bit names. Writes use the selected format and inverse scale. Zero scale cannot be written.\n\nCSV imports map source columns to name/kind/address and optional fields. Exports let you choose columns. Enter a local file path. Snapshots retain raw values; comparison never writes to devices.',
  'Logging / alarms': 'Add rows to Register map, then open Data logger. Choose CSV or JSONL, file path, interval and rows. CSV stores time plus one column per selected row. Stop/disconnect closes the file. Logging skips busy intervals.\n\nEdit alarm rules in the row editor. The first matching rule evaluates the scaled primary value, colors the row and logs/sounds on entry. Hex and ASCII rows do not trigger numeric alarms. Linux sound depends on desktop audio.',
  'Modes': 'Simulator: set listen transport/unit, add map rows and assign rules. Blank rule = manual. Expressions support [row name], t (seconds), prev, arithmetic, sin/cos, rand() and randint(a,b). Typing a reference/function prefix offers suggestions; Up/Down selects, Enter/Tab inserts, Escape dismisses. Invalid/nonfinite results do not write.\n\nSniffer: uses a separate serial adapter and never transmits. Recovered values are grouped by unit. Name registers, filter by area/name/address, hide or restore views, resize/reorder columns, open a graph for the selected unit, view traffic and export CSV. Refresh map recovers values after event overflow.\n\nGateway: choose listen and target transports; optional comma-separated unit allowlist. Transactions use the existing transparent forwarding backend. Stop releases listen/target resources.',
  'Graphs': 'Multi-series graph overlays collected curves from register map, logging and sniffer reads. Choose time window, normalize curves, pause display, zoom/pan and export timestamped samples. Histories are bounded. Open Graph from the map while map polling to see live curves.',
  'Storage / templates': 'Settings collects appearance, language, workspace save/import/export and the autosave preference. Use Save workspace to keep preferences when autosave is off. Workspace autosaves separately under ~/.modbus_connector/flutter/settings.json. Reopened sessions are disconnected. Workspace export/import excludes cloud credentials. MODBUS_FLUTTER_HOME changes the Flutter storage root.\n\nPublic templates are read-only. Custom templates use a separate Flutter history store. Save as custom creates an identity; Save new version appends a snapshot. Older versions open in new disconnected tabs. The last version cannot be deleted alone.',
};
const helpChinese = {
  'Sessions': '使用 + 添加独立会话。模式菜单切换主站、模拟器、监听器及网关。切换模式会先断开连接；关闭标签页会等待当前事务完成。后台标签页继续工作。\n\n主站支持 TCP、串口 RTU、RTU over TCP/UDP 和本地 TCP 演示。地址从 0 开始。停止轮询会丢弃迟到的结果。通过“工作区 → 本地演示”打开独立演示标签页，会预置六行示例并自动连接、轮询。信号动态变化，设定温度、计数值和开关可写；重新连接会重置演示数值。',
  'Registers / CSV / snapshots': '连接参数下方的寄存器映射是主站统一的读写区域。可手动添加命名行或加载模板，再使用“读取映射”或“轮询映射”访问不同站号和功能区；表格随窗口高度伸展。通过“连接设置”弹窗修改串口、网络、站号与超时参数，应用时校验并保存，取消则放弃修改。活动记录在右侧，可收起；窄窗口从右侧抽屉打开。“会话工具”包含报文、数据记录、扫描器及诊断。“更多工具”展开图表、表达式、合并读取、CSV 和快照。拖动表头可调整列顺序，拖动边缘可调整列宽；单击表头可移动或重置列。筛选栏可组合名称关键词、从 0 开始的地址或范围（十进制或 0x 十六进制）、轮询状态及功能区；地址范围包含覆盖该范围的多字寄存器行。显示匹配行数与总数，可一键清除筛选。筛选只控制显示，不限制整表读取、轮询、CSV 导出或快照。修改筛选会清除选择；全选和批量操作仅作用于可见行，移动时跳过隐藏行。“选择”列用于批量操作；按住鼠标左键沿该列滑动，每行在同一次拖动中只翻转一次，拖到上下边缘可自动滚动。使用底部浮动操作栏的“启用轮询 / 取消轮询”按钮批量设置选中行，也可使用右键菜单，停用行的名称旁显示暂停标记；选择操作不会改变轮询设置。点击行可编辑数量、格式、字节顺序、倍率、偏移、单位和值/位名称。写入采用显示格式及逆缩放；倍率为零时不能写入。\n\nCSV 导入可映射源列到 name/kind/address 等字段；导出可选择列并输入本地路径。快照保存原始值；比较不会向设备写入。',
  'Logging / alarms': '先在寄存器映射中添加行，再打开数据记录器，选择 CSV/JSONL、路径、间隔及行。CSV 为时间戳加各行的列。停止或断开会关闭文件；忙碌时跳过采样。\n\n行编辑器支持有序报警规则。首个匹配规则按缩放后的首值判断，着色并在触发时记录/响铃。Hex/ASCII 不进行数值报警。Linux 声音取决于桌面音频配置。',
  'Modes': '模拟器：设置监听方式与站号，添加行并配置规则。空规则为手动。支持 [行名]、t（秒）、prev、算术、sin/cos、rand() 和 randint(a,b)。输入引用或函数前缀会显示候选项；上下键选择，Enter/Tab 插入，Esc 隐藏候选项。无效或非有限结果不写入。\n\n监听器：使用独立串口适配器，绝不发送。按站号恢复数值，可命名，按功能区、名称或地址过滤，隐藏或恢复视图，调整列宽与列顺序，打开选中站号图表、查看报文和导出 CSV。事件溢出后可刷新映射。\n\n网关：设置监听端、目标端和可选的逗号分隔站号白名单。停止后释放两端资源。',
  'Graphs': '多曲线图叠加寄存器映射、数据记录及监听器采集的曲线。可选择时间窗口、各曲线归一化、暂停显示、缩放平移和导出采样。历史数据有容量限制；在映射轮询时打开图表可实时观察。',
  'Storage / templates': '设置集中提供外观、语言、工作区保存/导入/导出及自动保存偏好。关闭自动保存时，请使用“保存工作区”保留设置。工作区独立保存在 ~/.modbus_connector/flutter/settings.json，恢复后保持断开状态。导出不包含云凭据。MODBUS_FLUTTER_HOME 可改变 Flutter 存储目录。\n\n公共模板只读；自定义模板独立保存历史版本。“另存为自定义模板”创建新身份；“保存新版本”追加快照。旧版本在新的未连接标签页中打开。最后一个版本不能单独删除。',
};
Future<void> showFeatureHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => DefaultTabController(
    length: helpEnglish.length,
    child: AlertDialog(
      title: const LText('Help / feature guide'),
      content: SizedBox(
        width: 800,
        height: 450,
        child: Column(
          children: [
            TabBar(
              isScrollable: true,
              tabs: helpEnglish.keys.map((k) => Tab(child: LText(k))).toList(),
            ),
            Expanded(
              child: TabBarView(
                children: helpEnglish.keys
                    .map(
                      (k) => SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(
                          (appLanguage.value == 'zh_CN'
                              ? helpChinese
                              : helpEnglish)[k]!,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const LText('Close'),
        ),
      ],
    ),
  ),
);
