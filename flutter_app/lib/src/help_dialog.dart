import 'package:flutter/material.dart';

import 'translations.dart';

const helpEnglish = {
  'Sessions': 'Use + to add an independent session. The mode menu switches between Master, Simulator, Sniffer and Gateway. Switching mode disconnects first. Closing a tab waits for its active transaction. Inactive tabs keep working.\n\nMaster supports TCP, serial RTU, RTU over TCP/UDP and a local TCP demo. Addresses are 0-based PDU addresses. Stop polling discards late results.',
  'Registers / CSV / snapshots': 'The master range is a quick contiguous view. Open Register map for named rows across units and areas. Tap a row to edit count, format, byte order, scale/offset, engineering units and value/bit names. Writes use the selected format and inverse scale. Zero scale cannot be written.\n\nCSV imports map source columns to name/kind/address and optional fields. Exports let you choose columns. Enter a local file path. Snapshots retain raw values; comparison never writes to devices.',
  'Logging / alarms': 'Add rows to Register map, then open Data logger. Choose CSV or JSONL, file path, interval and rows. CSV stores time plus one column per selected row. Stop/disconnect closes the file. Logging skips busy intervals.\n\nEdit alarm rules in the row editor. The first matching rule evaluates the scaled primary value, colors the row and logs/sounds on entry. Hex and ASCII rows do not trigger numeric alarms. Linux sound depends on desktop audio.',
  'Modes': 'Simulator: set listen transport/unit, add map rows and assign rules. Blank rule = manual. Expressions support [row name], t (seconds), prev, arithmetic, sin/cos, rand() and randint(a,b). Invalid/nonfinite results do not write.\n\nSniffer: uses a separate serial adapter and never transmits. Recovered values are grouped by unit. Name registers, view traffic and export CSV. Refresh map recovers values after event overflow.\n\nGateway: choose listen and target transports; optional comma-separated unit allowlist. Transactions use the existing transparent forwarding backend. Stop releases listen/target resources.',
  'Graphs': 'The main chart follows the selected quick-range register. Multi-series graph overlays collected curves from master/map/logging/sniffer reads. Choose time window, normalize curves, pause display, zoom/pan and export timestamped samples. Histories are bounded. Open Graph from the map while map polling to see live curves.',
  'Storage / templates': 'Workspace autosaves separately under ~/.modbus_connector/flutter/settings.json. Reopened sessions are disconnected. Workspace export/import excludes cloud credentials. MODBUS_FLUTTER_HOME changes the Flutter storage root.\n\nPublic templates are read-only. Custom templates use a separate Flutter history store. Save as custom creates an identity; Save new version appends a snapshot. Older versions open in new disconnected tabs. The last version cannot be deleted alone.',
};
const helpChinese = {
  'Sessions': '使用 + 添加独立会话。模式菜单切换主站、模拟器、监听器及网关。切换模式会先断开连接；关闭标签页会等待当前事务完成。后台标签页继续工作。\n\n主站支持 TCP、串口 RTU、RTU over TCP/UDP 和本地 TCP 演示。地址从 0 开始。停止轮询会丢弃迟到的结果。',
  'Registers / CSV / snapshots': '主站范围是连续地址的快捷视图。寄存器映射支持跨站号和功能区的命名行。点击行可编辑数量、格式、字节顺序、倍率、偏移、单位和值/位名称。写入采用显示格式及逆缩放；倍率为零时不能写入。\n\nCSV 导入可映射源列到 name/kind/address 等字段；导出可选择列并输入本地路径。快照保存原始值；比较不会向设备写入。',
  'Logging / alarms': '先在寄存器映射中添加行，再打开数据记录器，选择 CSV/JSONL、路径、间隔及行。CSV 为时间戳加各行的列。停止或断开会关闭文件；忙碌时跳过采样。\n\n行编辑器支持有序报警规则。首个匹配规则按缩放后的首值判断，着色并在触发时记录/响铃。Hex/ASCII 不进行数值报警。Linux 声音取决于桌面音频配置。',
  'Modes': '模拟器：设置监听方式与站号，添加行并配置规则。空规则为手动。支持 [行名]、t（秒）、prev、算术、sin/cos、rand() 和 randint(a,b)。无效或非有限结果不写入。\n\n监听器：使用独立串口适配器，绝不发送。按站号恢复数值，可命名、查看报文和导出 CSV。事件溢出后可刷新映射。\n\n网关：设置监听端、目标端和可选的逗号分隔站号白名单。停止后释放两端资源。',
  'Graphs': '主界面图表跟踪选中的快捷寄存器。多曲线图叠加主站、映射、记录及监听器采集的曲线。可选择时间窗口、各曲线归一化、暂停显示、缩放平移和导出采样。历史数据有容量限制；在映射轮询时打开图表可实时观察。',
  'Storage / templates': '工作区独立保存在 ~/.modbus_connector/flutter/settings.json，恢复后保持断开状态。导出不包含云凭据。MODBUS_FLUTTER_HOME 可改变 Flutter 存储目录。\n\n公共模板只读；自定义模板独立保存历史版本。“另存为自定义模板”创建新身份；“保存新版本”追加快照。旧版本在新的未连接标签页中打开。最后一个版本不能单独删除。',
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
