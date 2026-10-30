# Modbus Connector 模板格式

此参考来自本仓库 `src/modbus_connector/templates/__init__.py`、`models.py`、
`connection_panel.py`、`registers_panel.py` 和 `flutter_catalog.py`。
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
现有模板可省略 kind/format，加载器及校验器分别按 holding_registers/dec 处理。

| 字段 | 规则 |
| --- | --- |
| `kind` | FC01=`coils`，FC02=`discrete_inputs`，FC03=`holding_registers`，FC04=`input_registers` |
| `address` | 整数 PDU 起始地址，0–65535；不能直接照搬 4xxxx 编号 |
| `count` | 位区为位数，寄存器区为 16 位字数；每行最多 2000 位或 125 字，结束地址不超过 65535 |
| `format` | `dec`（u16）、`hex`、`s16`、`u32`、`s32`、`f32`、`u64`、`s64`、`f64`、`ascii`、`ascii1` |
| `order` | `ABCD`、`CDAB`、`BADC`、`DCBA`；省略/空字符串继承全局设置 |
| `scale` / `offset` | 显示值 = 解码后的数值 × scale + offset；默认 1 / 0 |
| `unit` | 显示单位字符串，例如 `℃`、`Hz`；不是设备站号 |
| `unit_id` | 每行站号覆盖，建议用整数 1–247；省略则继承 connection.unit |
| `value_names` | 对象：十进制整数字符串 → 名称，例如 `{"0":"停止","1":"运行"}` |
| `bitmask` | true 时 value_names 的键是 0–15 位号，而非掩码值；默认 false |
| `poll_enabled` | 布尔值；默认 true；需要条件才能读的已确认字段可设 false 并说明条件 |
| `trend_enabled` | 布尔值；生成模板默认显式 false，用户需要趋势时再开启 |

32 位数至少占 2 字，64 位数至少占 4 字。数值数组的 count 应为格式宽度的整数倍。
`ascii` 每字两字符；`ascii1` 每字低字节一个字符，必须核对固件序列化。
位区使用 `dec`；枚举或位掩码的跨客户端可交互显示建议限定于 count=1 的
`dec/s16/hex` 行。多字位域拆成有依据的单字行并分别映射位号，不把位 16 写入单字位表。
枚举键按解码值填写，不应用 scale；不要把运行时值或写入默认值放进模板。

`holding_registers` 可以包含固件拒绝写入的只读字段。不要因为字段只读就改成
`input_registers`，也不要杜撰 `read_only`/`writable` 字段来声称 GUI 会禁止写入。
权限、有效范围、哨兵值和依赖条件记入来源说明。

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
     "count": 1, "format": "s16", "scale": 0.1, "unit": "℃", "trend_enabled": false},
    {"name": "状态", "kind": "holding_registers", "address": 101,
     "count": 1, "format": "dec", "value_names": {"0": "停止", "1": "运行"},
     "trend_enabled": false},
    {"name": "故障", "kind": "holding_registers", "address": 102,
     "count": 1, "format": "hex", "bitmask": true,
     "value_names": {"0": "传感器故障", "3": "高压保护"}, "trend_enabled": false}
  ]
}
```
