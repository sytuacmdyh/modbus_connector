const applicationVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: String.fromEnvironment(
    'FLUTTER_BUILD_NAME',
    defaultValue: 'development',
  ),
);

const releasesUrl = 'https://github.com/sytuacmdyh/modbus_connector/releases';

const recentReleases = [
  (
    version: '0.16.20',
    english: [
      'Enter a custom raw value and choose an enum preset in the same dialog.',
      'The current value is focused and selected automatically. Press Enter to write.',
    ],
    chinese: ['枚举快捷选项与自定义原始值输入合并到同一弹窗。', '打开后自动聚焦并全选当前值，输入后按 Enter 即可写入。'],
  ),
  (
    version: '0.16.19',
    english: [
      'Read groups are distributed across stations while preserving order within each station and write priority.',
    ],
    chinese: ['多站轮询交错读取各站分组，保留站内顺序和写入优先级。'],
  ),
  (
    version: '0.16.18',
    english: [
      'Enum registers accept custom raw values alongside preset choices.',
      'Received data is logged as complete Modbus frames. RTU requests wait at least 50 ms after the latest activity.',
    ],
    chinese: [
      '枚举寄存器支持快捷选项之外的自定义原始值。',
      '通信日志按完整 Modbus 帧记录，RTU 请求在最近一次通信活动后至少等待 50 ms。',
    ],
  ),
];
