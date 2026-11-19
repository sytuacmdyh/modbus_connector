# Modbus Connector 模板格式

此参考来自本仓库 `flutter_app/lib/src/backend/registers.dart`、`catalog.dart`、
`files.dart`、`register_map.dart`、`register_overview.dart` 和
`src/modbus_connector/templates/__init__.py`。桌面呈现行为以 Dart 实现为准。
若用户指定其他版本且源码可用，以其加载实现为准；不要猜测新字段。

## 文件和连接

目录项为 `<Manufacturer>/<Device>.json`，顶层必须有非空字符串 `name`、对象
`connection` 和数组 `registers`。`description` 可说明型号、协议版本和来源。
在 modbus_connector 仓库添加内置模板时写入 `src/modbus_connector/templates/`；
在其他目标项目中生成文件不会自动把它注册到已安装应用的菜单。

`connection` 使用 兼容公共模板字段（Flutter 模板加载器会转换）：

| 字段 | 值与意义 |
| --- | --- |
| `type` | `RTU`、`TCP`、`RTU over TCP`、`RTU over UDP` |
| `unit` | 整数设备地址，一般 1–247；读模板不要使用广播地址 0 |
| `rtu_baud` | 字符串，如 `"9600"`，必须有设备依据 |
| `rtu_bytesize` / `rtu_parity` / `rtu_stopbits` | 字符串，如 `"8"` / `"N"` / `"1"` |
| `rtu_port` | 用户指定的串口；可省略，不虚构 COM 端口 |
| `tcp_host` / `tcp_port` | 主机字符串 / 整数端口；缺少目标地址时说明需配置 |
| `timeout` | 正数，单位秒，客户端选项而非设备协议参数 |

可省略未确认的连接字段，加载时应用会提供默认值；来源说明中明确这些默认值未获设备验证。

## 寄存器行

生成的每行明确填写 `name`、`kind`、`address`、`count`、`format`。
现有模板可省略 kind/format，加载器及校验器分别按 holding_registers/u16 处理；旧模板
中的 `dec` 拼写仍兼容并会规范化为 `u16`。

| 字段 | 规则 |
| --- | --- |
| `kind` | FC01=`coils`，FC02=`discrete_inputs`，FC03=`holding_registers`，FC04=`input_registers` |
| `address` | 整数 PDU 起始地址，0–65535；不能直接照搬 4xxxx 编号 |
| `count` | 位区为位数，寄存器区为 16 位字数；每行最多 2000 位或 125 字，结束地址不超过 65535 |
| `format` | `u16`（旧别名 `dec`）、`hex`、`s16`、`u32`、`s32`、`f32`、`u64`、`s64`、`f64`、`ascii`、`ascii1` |
| `order` | `ABCD`、`CDAB`、`BADC`、`DCBA`；省略/空字符串继承全局设置 |
| `scale` / `offset` | 显示值 = 解码后的数值 × scale + offset；默认 1 / 0 |
| `unit` | 显示单位字符串，例如 `℃`、`Hz`；不是设备站号 |
| `unit_id` | 每行站号覆盖，建议用整数 1–247；省略则继承 connection.unit |
| `value_names` | 对象：十进制整数字符串 → 名称，例如 `{"0":"停止","1":"运行"}` |
| `bitmask` | true 时 value_names 的键是 0–15 位号，而非掩码值；默认 false |
| `poll_enabled` | 布尔值；默认 true；需要条件才能读的已确认字段可设 false 并说明条件 |
| `trend_enabled` | 布尔值；生成模板默认显式 false，用户需要趋势时再开启 |
| `writable` | 可选布尔值；false 禁止通过该行写入；true 仅允许用于 holding/coil；省略按区域沿用旧行为 |
| `overview_id` | 可选非空字符串，同一模板内唯一；概览用它稳定引用该行，重排行序时保留 |

32 位数至少占 2 字，64 位数至少占 4 字。数值数组的 count 应为格式宽度的整数倍。
`ascii` 每字两字符；`ascii1` 每字低字节一个字符，必须核对固件序列化。
位区使用 `u16`（旧别名 `dec`）；枚举或位掩码的跨客户端可交互显示建议限定于 count=1 的
`u16/s16/hex` 行。多字位域拆成有依据的单字行并分别映射位号，不把位 16 写入单字位表。
枚举键按解码值填写，不应用 scale；不要把运行时值或写入默认值放进模板。

`holding_registers` 可以包含固件拒绝写入的只读字段：保持原来的 `kind`，并设
`writable: false`；不要因此改成 `input_registers`。已确认可写的 holding/coil 可设
true，权限不明时省略并在来源说明中注明。字段必须为 JSON 布尔值，不能写成字符串或 null。
该权限覆盖整行，连续地址中混有只读/可写字段时拆行；不支持位级权限或条件写权限。
新 Flutter 客户端在寄存器表及其后端行写入中执行限制，旧客户端可能忽略此字段。
它不是设备端权限，也不限制独立 CLI/MCP 原始地址操作。有效范围、哨兵值和依赖条件仍记入来源说明。

## 概览与表格布局

公共模板可在顶层 `draft` 中携带 `map_overview` 和可选的 `map_split_ratio`。
旧式 `registers_options.flutter.draft` 仍可加载：先应用顶层 draft，再浅合并旧式 draft；
同名字段以后者为准，`map_overview` 整体替换，不递归合并区块。新模板优先只使用顶层 draft，
更新旧模板时保持其结构，避免两处配置相互覆盖。

| 字段 | 规则 |
| --- | --- |
| `draft.map_split_ratio` | 左侧宽度占比，有限数值 0.28–0.62；省略默认 0.42，用户可拖动分隔线调整 |
| `draft.map_overview.blocks` | 有序区块数组，例如风机、水泵、温度；`[]` 表示主动清空，不能当成缺省配置 |
| 区块 `name` / `enabled` / `items` | 非空名称 / 可选布尔值（默认 true）/ 有序内容数组；允许空区块 |
| 内容 `row_id` | 对应寄存器行的 `overview_id`；可用 uuid4().hex 为新引用行生成 ID，已有 ID 不变 |
| 内容 `label` | 可选显示名称，省略沿用寄存器名称 |
| 内容 `rules` | 可选有序颜色规则数组，首条匹配生效；省略沿用该行报警颜色，`[]` 明确禁用这种回退 |

同一行可出现在多个区块中，同一区块内不要重复引用。新生成内容使用 `row_id`；
兼容旧内容 `row`（当前 registers 数组的零起始下标），它必须在范围内，且不能与 row_id 同时存在。
不要仅因调整行序就重建 ID 或把稳定引用改回下标；旧下标引用遇到增删、重排必须同步维护。
概览缺省时客户端显示全部寄存器的默认 Registers 区块。概览无需图标，不生成 icon 等无效配置。

颜色规则字段：`condition`、`value`、可选 `value2` 和可选 `color`（仅 red/yellow，默认 red）。
条件为 `gt/ge/lt/le/eq/ne/in_range/outside_range`；阈值必须是有限数值，不能是字符串或布尔值。
两个范围条件都需要 value2，范围包含端点，反向上下限会归一化；其余条件不填 value2。
规则比较的是应用缩放、偏移后的第一个数值，不是原始字、枚举文字或位名称；hex/ascii 等
不提供数值的格式不匹配规则。未匹配时使用主题默认颜色，不杜撰 green 或十六进制颜色。
旧规则中的布尔 log/sound 可以保留，但概览规则只影响颜色，不触发报警日志或声音。
阈值来源写入 `.sources.md`；示例阈值不能直接套到真实设备。

左侧始终只读并复用已有采集结果；显示哪些行不改变 `poll_enabled` 或读写权限。
右侧访问筛选默认“可写”，只影响表格可见行，不影响概览、采集、CSV 或快照。
不要为让只读状态出现在概览而改成可写，也不要用停采集来隐藏概览内容。

新布局默认仅显示选择、地址、名称、值和操作等必要列，其他列可由列设置开启。
未指定表格偏好时，省略 `registers_options.hidden_columns` 和 `draft.map_table.hidden`；
显式空数组表示“不隐藏任何列”，会覆盖精简默认值。保留现有列设置及行高偏好，
不要为了生成模板新增行高切换、比例提示等界面字段。

## 地址与编码核对

- 只有来源明确采用 40001→PDU 0 的编号约定时才减 40001。固件直接比较的
  `40001` 也可能就是实际 PDU 地址。检查接收地址到映射表的完整转换路径。
- 16 位补码 `0xFF9C` 用 s16 解码为 -100；scale=0.1 后为 -10。
- 按高字在前返回 `[0x3F80,0x0000]` 的 IEEE754 数据用 f32/ABCD 显示 1.0；
  低字在前的同一个值使用 CDAB。整数乘比例与 IEEE754 不是同一种表示。
- 注释、宏展开、连续数组和 switch case 必须结合所选编译条件；内部数组下标不是天然 PDU 地址。

## 示例（虚构设备，只示范格式）

```json
{
  "name": "示例温控器",
  "description": "格式示例，不代表真实设备寄存器",
  "connection": {"type": "RTU", "unit": 1, "rtu_baud": "9600"},
  "registers": [
    {"name": "温度", "kind": "holding_registers", "address": 100,
     "count": 1, "format": "s16", "scale": 0.1, "unit": "℃", "trend_enabled": false,
     "writable": false, "overview_id": "example-temperature"},
    {"name": "状态", "kind": "holding_registers", "address": 101,
     "count": 1, "format": "u16", "value_names": {"0": "停止", "1": "运行"},
     "trend_enabled": false, "overview_id": "example-state"},
    {"name": "故障", "kind": "holding_registers", "address": 102,
     "count": 1, "format": "hex", "bitmask": true,
     "value_names": {"0": "传感器故障", "3": "高压保护"}, "trend_enabled": false,
     "overview_id": "example-fault"}
  ],
  "draft": {
    "map_split_ratio": 0.42,
    "map_overview": {
      "blocks": [
        {"name": "温度", "enabled": true, "items": [
          {"row_id": "example-temperature", "label": "环境温度", "rules": [
            {"condition": "ge", "value": 80, "color": "red"},
            {"condition": "ge", "value": 60, "color": "yellow"}
          ]}
        ]},
        {"name": "设备状态", "items": [
          {"row_id": "example-state"},
          {"row_id": "example-fault", "rules": []}
        ]}
      ]
    }
  }
}
```
