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
    version: '0.16.21',
    english: [
      'The toolbar shows the current version and opens recent release notes.',
      'Recent updates are available offline in English and Chinese on desktop and web.',
    ],
    chinese: [
      '顶部展示当前版本号，点击即可查看最近更新内容。',
      '更新说明支持中英文和离线查看，桌面端与网页端共用。',
    ],
  ),
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
];
