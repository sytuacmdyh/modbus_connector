import 'dart:io';

import 'package:flutter/material.dart';

import 'qt_translations.dart';

final appLanguage = ValueNotifier<String>('en');
final appTheme = ValueNotifier<ThemeMode>(ThemeMode.system);
String tr(String value) =>
    appLanguage.value == 'zh_CN' ? _translate(value, 0) : value;

final _dynamicChinese = <(RegExp, String, List<String>)>[
  for (final entry in {...qtChinese, ...flutterChinese}.entries)
    if (RegExp(r'\{\w+\}').hasMatch(entry.key))
      _translationPattern(entry.key, entry.value),
];

(RegExp, String, List<String>) _translationPattern(
  String key,
  String translation,
) {
  final pattern = StringBuffer('^');
  final names = <String>[];
  var offset = 0;
  for (final match in RegExp(r'\{(\w+)\}').allMatches(key)) {
    pattern.write(RegExp.escape(key.substring(offset, match.start)));
    pattern.write('(.*?)');
    names.add(match.group(1)!);
    offset = match.end;
  }
  pattern.write(RegExp.escape(key.substring(offset)));
  pattern.write(r'$');
  return (RegExp(pattern.toString(), dotAll: true), translation, names);
}

String _translate(String value, int depth) {
  final exact = flutterChinese[value] ?? qtChinese[value];
  if (exact != null) return exact;
  if (depth > 2) return value;
  for (final (pattern, translation, names) in _dynamicChinese) {
    final match = pattern.firstMatch(value);
    if (match == null) continue;
    var result = translation;
    for (var i = 0; i < names.length; i++) {
      result = result.replaceAll(
        '{${names[i]}}',
        _translate(match.group(i + 1)!, depth + 1),
      );
    }
    return result;
  }
  return value;
}

String userError(Object error) {
  if (error is FileSystemException) {
    return trf('File operation failed: {path} (OS error {code})', {
      'path': error.path ?? '',
      'code': error.osError?.errorCode ?? '—',
    });
  }
  if (error is FormatException) return tr(error.message);
  return tr(error.toString());
}

String trf(String key, Map<String, Object?> values) {
  var text = tr(key);
  for (final e in values.entries) {
    text = text.replaceAll('{${e.key}}', '${e.value}');
  }
  return text;
}

const flutterChinese = <String, String>{
  'Stop map polling': '停止映射轮询',
  'Browse': '浏览',
  'Save': '保存',
  'Open': '打开',
  'Import CSV file path': '导入 CSV 文件路径',
  'Export CSV file path': '导出 CSV 文件路径',
  'Export graph samples CSV file path': '导出图表采样 CSV 路径',
  'Export selected unit CSV file path': '导出选中站号 CSV 路径',
  'Import Flutter workspace file path': '导入 Flutter 工作区路径',
  'Export Flutter workspace file path': '导出 Flutter 工作区路径',
  'Export graph PNG file path': '导出图表 PNG 路径',
  'Export PNG': '导出 PNG',
  'Saved': '已保存',
  'Image export failed': '图像导出失败',
  'Click to pin a sample; click again to follow the pointer.':
      '单击固定采样位置，再次单击跟随指针。',
  'Snapshot files': '快照文件',
  'Import snapshots': '导入快照',
  'Export snapshots': '导出快照',
  'Import snapshots file path': '导入快照文件路径',
  'Export snapshots file path': '导出快照文件路径',
  'Snapshots imported': '快照已导入',
  'Snapshots exported': '快照已导出',
  'Snapshot file failed': '快照文件操作失败',
  'Invalid snapshots file': '无效快照文件',
  'min': '最小',
  'max': '最大',
  'mean': '平均',
  'Last scan': '上次扫描',
  'hits': '个响应',
  'stopped': '已停止',
  'Sniffer view': '监听数据视图',
  'Multiword views require consecutive recovered addresses.': '多字视图需要已恢复的连续地址。',
  'Selected unit only': '仅选中站号',
  'Load template rows': '加载模板行',
  'Template rows skipped': '跳过的模板行数',
  'Add rows to simulator': '向模拟器添加行',
  'Add selected version rows': '添加选中版本的行',
  'Template rows append to the simulator; duplicate area/address pairs are skipped.':
      '模板行追加到模拟器；重复的区域与地址将被跳过。',
  'Blank rule means manual': '规则留空时手动设置',
  'Insert a reference or function at the cursor': '在光标处插入引用或函数',
  'Invalid rule syntax': '规则语法无效',
  'Rule result is not finite': '规则结果不是有限数值',
  'Rule reference is unavailable': '规则引用的行不可用',
  'Rule evaluation or encoding failed': '规则求值或编码失败',
  'Set {name} ({format})': '设置 {name}（{format}）',
  'Read selected rows': '读取选中行',
  'Enable selected polling': '启用选中行轮询',
  'Disable selected polling': '禁用选中行轮询',
  'Duplicate selected rows': '复制选中行',
  'Delete selected rows': '删除选中行',
  'Selected rows': '选中行',
  'Poll enabled': '启用轮询',
  'Move up': '上移',
  'Move down': '下移',
  'copy': '副本',
  'Expressions read fresh map dependencies at each logging tick.':
      '记录表达式时，每次采样都会重新读取映射中的依赖项。',
  'Snapshot name': '快照名称',
  'Snapshot {name} differences': '快照 {name} 的差异',
  'No differences': '无差异',
  'Write {name} ({format}, engineering units)': '写入 {name}（{format}，工程单位）',
  'File operation failed: {path} (OS error {code})':
      '文件操作失败：{path}（系统错误 {code}）',
  'Could not save workspace: {error}': '无法保存工作区：{error}',
  'Could not restore workspace: {error}': '无法恢复工作区：{error}',
  'Check address/count, format width, unit (1–247), and finite scale/offset.':
      '请检查地址、数量、站号、格式宽度及倍率与偏移。',
  'Choose a path and interval 100–86400000 ms': '请选择路径及 100–86400000 毫秒的间隔',
  'Choose a file path and csv/jsonl format': '请选择文件路径及 csv/jsonl 格式',
  'Select 1..512 rows to log': '请选择 1–512 行进行记录',
  'Invalid logger settings': '无效的记录设置',
  'Logger is not running': '记录器未运行',
  'Sample does not match logger columns': '采样与记录器列不一致',
  'Invalid raw sample': '无效的原始采样',
  '{name} must be an integer in {low}..{high}':
      '{name} 必须是 {low} 到 {high} 之间的整数',
  '{name} must be finite': '{name} 必须是有限数值',
  'Unknown register area or display format': '未知的寄存器区域或显示格式',
  'Unknown byte order': '未知的字节顺序',
  'Invalid row range or count smaller than display width': '行地址范围无效或数量小于格式宽度',
  'Simulator unit: blank for any, or one unit 1–247':
      '模拟器站号：留空为任意，或输入 1–247 的站号',
  'Event buffer overflow ({count} events); use Refresh map.':
      '事件缓冲区溢出（{count} 个事件）；请刷新映射。',
  'Probe: area,address,count': '探测项：区域,地址,数量',
  'Unit {unit} identification': '站号 {unit} 的设备标识',
  'Unit {unit}': '站号 {unit}',
  '{mode} session': '{mode}会话',
  'Value: {value}': '数值：{value}',
  'Logging · {count} samples written': '记录中 · 已写入 {count} 个样本',
  'Alarm rules ({count})': '报警规则（{count}）',
  'Bits · 0x{value}': '位 · 0x{value}',
  'Saved {path}': '已保存 {path}',
  'poll_ms': '轮询间隔（毫秒）',
  'format': '格式',
  'kind': '区域',
  'name': '名称',
  'value': '数值',
  'order': '字节顺序',
  'timestamp': '时间戳',
  'manual': '手动',
  'added': '已添加',
  'removed': '已移除',
  'Unit {unit} · probes {probes}': '站号 {unit} · 探测项 {probes}',
  'Workspace': '工作区',
  'New session': '新建会话',
  'Session mode': '会话模式',
  'master': '主站',
  'simulator': '模拟器',
  'sniffer': '监听器',
  'gateway': '网关',
  'Save workspace': '保存工作区',
  'Export workspace': '导出工作区',
  'Import workspace': '导入工作区',
  'Templates / history': '模板与历史版本',
  'Register map': '寄存器映射',
  'Register map / CSV / snapshots': '寄存器映射 / CSV / 快照',
  'Add row': '添加行',
  'Read map': '读取映射',
  'Poll map': '轮询映射',
  'Import CSV': '导入 CSV',
  'Export CSV': '导出 CSV',
  'Snapshot': '快照',
  'Compare snapshot': '比较快照',
  'Graph map': '映射图表',
  'Register row': '寄存器行',
  'Area': '区域',
  'Format': '格式',
  'Byte order': '字节顺序',
  'Name': '名称',
  'address': '地址',
  'count': '数量',
  'unit_id': '站号（可空）',
  'scale': '倍率',
  'offset': '偏移',
  'unit': '单位',
  'Value names: number=name (one per line)': '值名称：数字=名称（每行一项）',
  'Names label bits 0–15': '使用名称标记 0–15 位',
  'Edit bits': '编辑位',
  'Write row': '写入行',
  'Delete row': '删除行',
  'Data logger': '数据记录器',
  'Append to existing file': '追加到已有文件',
  'Output file path': '输出文件路径',
  'Stop logging': '停止记录',
  'Start logging': '开始记录',
  'Replace existing log file?': '替换现有日志文件？',
  'Replace': '替换',
  'Stopped': '已停止',
  'Running': '运行中',
  'Timestamp': '时间戳',
  'Add rows in Register map before starting.': '请先在寄存器映射中添加行。',
  'CSV: timestamp + one column per selected row. Logging reads at this interval; busy ticks are skipped.':
      'CSV：时间戳及各选定行的列。按间隔采样；忙碌时跳过。',
  'Alarm rules · first match wins': '报警规则 · 首个匹配生效',
  'Condition': '条件',
  'Threshold / lower': '阈值 / 下限',
  'Upper': '上限',
  'Color': '颜色',
  'Log on entry': '触发时记录',
  'Sound on entry': '触发时响铃',
  'Add rule': '添加规则',
  'Higher priority': '提高优先级',
  'Remove rule': '删除规则',
  'Multi-series graph': '多曲线图表',
  'Time window, s': '时间窗口（秒）',
  'Normalize each curve': '各曲线归一化',
  'Resume chart': '恢复图表',
  'Pause chart': '暂停图表',
  'Export samples': '导出采样',
  'Clear': '清空',
  'Scroll/pinch to zoom; drag to pan. Up to 1000 samples per series, sampled at most 10 Hz.':
      '滚动或缩放手势放大，拖动平移。每条曲线最多 1000 个样本、10 Hz。',
  'Serial RTU': '串口 RTU',
  'Local demo': '本地演示',
  'Transport': '传输方式',
  'Host': '主机',
  'Port': '端口',
  'Serial port': '串口',
  'Baud': '波特率',
  'Bits': '数据位',
  'Parity': '校验',
  'Stop': '停止',
  'Timeout, s': '超时（秒）',
  'Unit': '站号',
  'Function area': '功能区',
  'Start · 0-based': '起始地址（从 0 开始）',
  'Count': '数量',
  'Interval, ms': '间隔（毫秒）',
  'Holding registers · 03': '保持寄存器 · 03',
  'Input registers · 04': '输入寄存器 · 04',
  'Coils · 01': '线圈 · 01',
  'Discrete inputs · 02': '离散输入 · 02',
  'holding_registers': '保持寄存器',
  'input_registers': '输入寄存器',
  'coils': '线圈',
  'discrete_inputs': '离散输入',
  'Start polling': '开始轮询',
  'Stop polling': '停止轮询',
  'Cancel connection': '取消连接',
  'Disconnecting…': '正在断开…',
  'Appearance': '外观',
  'System': '跟随系统',
  'Light': '浅色',
  'Dark': '深色',
  'Scan': '扫描',
  'Units': '站号',
  'Addresses': '地址',
  'From': '从',
  'To': '到',
  'Open selected range': '打开选定范围',
  'Use selected unit': '使用选定站号',
  'Edit probe': '编辑探测项',
  'Remove probe': '删除探测项',
  'Add probe': '添加探测项',
  'Templates / custom history': '模板 / 自定义历史',
  'Save as custom': '另存为自定义模板',
  'Save new version': '保存新版本',
  'Refresh catalog': '刷新目录',
  'Public (read-only)': '公共模板（只读）',
  'Custom (Flutter storage)': '自定义模板（Flutter 存储）',
  'Select a template': '选择模板',
  'Rename': '重命名',
  'Delete template': '删除模板',
  'Delete version': '删除版本',
  'Open latest in new tab': '在新标签页打开最新版',
  'Open selected version': '打开所选版本',
  'Opening creates a disconnected tab. Saving appends a new snapshot; public templates stay read-only.':
      '打开后创建未连接的标签页。保存会追加快照；公共模板只读。',
  'Listen': '监听端',
  'Target': '目标端',
  'Tick, ms': '规则间隔（毫秒）',
  'Set value': '设置数值',
  'Expression rule': '表达式规则',
  'Remove row': '删除行',
  'Traffic / events': '报文 / 事件',
  'Refresh map': '刷新映射',
  'Serial adapter (passive; never transmits)': '串口适配器（仅监听，不发送）',
  'Unit: blank=any': '站号：留空为任意',
  'Allowed units: blank=all; 1,2,3': '允许站号：留空为全部；如 1,2,3',
  'Help': '帮助',
  'Language': '语言',
  'Help / feature guide': '帮助 / 功能指南',
  'Sessions': '会话',
  'Registers / CSV / snapshots': '寄存器 / CSV / 快照',
  'Logging / alarms': '记录 / 报警',
  'Modes': '模式',
  'Graphs': '图表',
  'Storage / templates': '存储 / 模板',
};

class LText extends StatelessWidget {
  const LText(
    this.data, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.softWrap,
  });
  final String data;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final bool? softWrap;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: appLanguage,
    builder: (context, _, child) => Text(
      tr(data),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
      softWrap: softWrap,
    ),
  );
}
