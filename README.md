# followmotion

一个用于 macOS 的全局输入监听与模拟插件示例，提供：
- 全局键盘、鼠标（移动/按下/抬起）、滚轮事件流
- 键盘与鼠标事件的注入（模拟）
- 全局拦截：拦截所有键盘/鼠标，或拦截指定键码
- 屏幕尺寸获取、事件录制与回放

> 当前平台支持：仅 macOS（插件注册见 `pubspec.yaml` 中 `plugin.platforms.macos`）。

## 权限与系统设置（macOS）
使用本项目需要以下系统隐私权限：
- 辅助功能（Accessibility）
- 输入监控（Input Monitoring）

首次运行时，系统会提示授权，请在“系统设置 → 隐私与安全”中为应用授予上述权限；否则无法监听或注入全局事件。

## 快速开始
在你的代码中引入：
```dart
import 'package:followmotion/followmotion.dart' as fm;
```

订阅全局事件与模拟输入：
```dart
// 日志监听（可选）
fm.setLogListener((level, message) { debugPrint('[${level.name}] $message'); });

// 订阅全局事件
final sub = fm.globalInputEvents().listen((e) {
  if (e is fm.KeyEvent) {
    debugPrint('key code=${e.keyCode} down=${e.isDown} injected=${e.injected}');
  } else if (e is fm.MouseEvent) {
    debugPrint('mouse ${e.type} ${e.button} x=${e.x} y=${e.y}');
  } else if (e is fm.WheelEvent) {
    debugPrint('wheel dy=${e.deltaY}');
  }
});

// 模拟键盘
await fm.simulateKey(keyCode: 12, isDown: true);  // Q 按下
await fm.simulateKey(keyCode: 12, isDown: false); // Q 抬起

// 模拟鼠标
await fm.simulateMouse(type: 'move', x: 400, y: 300);
await fm.simulateMouse(type: 'down', x: 400, y: 300);
await fm.simulateMouse(type: 'up', x: 400, y: 300);

// 拦截设置
await fm.setInterceptAllKeys(true);
await fm.setInterceptAllMouse(true);
await fm.setInterceptedKeys([12, 13]); // 拦截 Q/W
await fm.clearInterceptedKeys();

// 屏幕尺寸
final size = await fm.getScreenSize();
```

事件录制与回放：
```dart
final recorder = fm.startRecording(includeInjected: false);
// ...交互若干...
await recorder.stop();
final json = recorder.toJson();
await fm.replayRecording(recorder, speed: 1.0);
```

## API 概览
- 事件流：
  - `Stream<GlobalInputEvent> fm.globalInputEvents()`
  - 事件类型：`KeyEvent(keyCode, isDown, injected)`、`MouseEvent(type, button, x, y)`、`WheelEvent(deltaY)`
- 模拟输入：
  - `fm.simulateKey({required int keyCode, required bool isDown})`
  - `fm.simulateMouse({required String type, required double x, required double y, String button = 'left'})`
- 拦截控制：
  - `fm.setInterceptAllKeys(bool)`、`fm.setInterceptAllMouse(bool)`
  - `fm.setInterceptedKeys(List<int>)`、`fm.clearInterceptedKeys()`
- 其他：
  - `fm.getScreenSize()` 获取主屏尺寸
  - 录制/回放：`EventRecorder`（`startRecording`, `stop`, `toJson`, `play`/`replayRecording`）

> 键码说明：使用 macOS 虚拟键码，例如 Q=12、W=13。更多键位可参考 Apple Virtual Keycodes 文档。

## 示例应用
`example/lib/main.dart` 提供完整演示：
- 首页：拦截开关、拦截键列表编辑、“录制包含注入事件”切换，以及进入模拟页
- 模拟页：半透明屏幕覆盖层映射真实坐标，支持鼠标移动/按下/抬起注入；事件列表实时显示；录制/序列化/复制/回放（含速度控制）
- 安全退出：5 秒内连续按 Q 十次可自动关闭拦截并清空拦截列表

运行示例（macOS）：
```bash
cd example
flutter pub get
flutter run -d macos
```

## 常见问题
- 无法收到事件或注入无效：检查“辅助功能”和“输入监控”权限是否已授予
- 多显示器：`getScreenSize()`返回主屏尺寸，坐标基于系统屏幕坐标（原点位于全局坐标系）
- 生产环境：请谨慎使用全局拦截与事件注入，确保提供明显的退出机制与用户提示
