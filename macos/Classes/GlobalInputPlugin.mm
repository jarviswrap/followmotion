#import <Cocoa/Cocoa.h>
#import <FlutterMacOS/FlutterMacOS.h>
#include <unistd.h>

static CFMachPortRef g_tap = NULL;
static FlutterEventSink g_sink = nil;
static NSMutableSet<NSNumber*>* g_block = nil;
static pid_t g_pid = 0;
static BOOL g_intercept_all_keys = NO;
static BOOL g_intercept_all_mouse = NO;

static CGEventRef TapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* refcon) {
  if (!g_sink) return event;
  pid_t src = (pid_t)CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
  if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
    int64_t code = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    g_sink(@{@"kind":@"key", @"keyCode":@(code), @"isDown":@(type==kCGEventKeyDown), @"injected":@(src==g_pid)});
    if (((g_intercept_all_keys) || (g_block && [g_block containsObject:@(code)])) && src != g_pid) { return NULL; }
  } else if (type == kCGEventMouseMoved ||
             type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp ||
             type == kCGEventRightMouseDown|| type == kCGEventRightMouseUp ||
             type == kCGEventOtherMouseDown|| type == kCGEventOtherMouseUp) {
    CGPoint p = CGEventGetLocation(event);
    NSString* t = (type==kCGEventMouseMoved?@"move":((type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown)?@"down":@"up"));
    NSString* b = ((type==kCGEventRightMouseDown||type==kCGEventRightMouseUp)?@"right":((type==kCGEventOtherMouseDown||type==kCGEventOtherMouseUp)?@"middle":@"left"));
    g_sink(@{@"kind":@"mouse", @"type":t, @"button":b, @"x":@(p.x), @"y":@(p.y)});
    if (g_intercept_all_mouse && src != g_pid) { return NULL; }
  } else if (type == kCGEventScrollWheel) {
    int64_t dy = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
    g_sink(@{@"kind":@"wheel", @"deltaY":@(dy)});
    if (g_intercept_all_mouse && src != g_pid) { return NULL; }
  }
  return event;
}

@interface GlobalInputPlugin : NSObject<FlutterPlugin, FlutterStreamHandler>
@end

@implementation GlobalInputPlugin
+ (void)registerWithRegistrar:(nonnull NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* mc = [FlutterMethodChannel methodChannelWithName:@"input_simulator" binaryMessenger:[registrar messenger]];
  FlutterEventChannel* ec = [FlutterEventChannel eventChannelWithName:@"global_input_events" binaryMessenger:[registrar messenger]];
  GlobalInputPlugin* instance = [GlobalInputPlugin new];
  [ec setStreamHandler:instance];
  [registrar addMethodCallDelegate:instance channel:mc];
}

- (FlutterError*)onListenWithArguments:(id)args eventSink:(FlutterEventSink)sink {
  // Dart 端对 EventChannel 发起首次订阅时触发此回调，用于启动全局输入事件监听并保存事件下沉器。
  // args 为 Dart 侧传入的可选参数；sink 用于持续推送事件到 Dart（global_input_events）。
  g_sink = sink;

  // 监听范围：键盘按下/抬起、鼠标移动、左/右/中键按下/抬起、滚轮。
  // 事件统一格式在 TapCallback 中构造并通过 g_sink(...) 发送到 Dart。
  CGEventMask mask =
    CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
    CGEventMaskBit(kCGEventMouseMoved) |
    CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
    CGEventMaskBit(kCGEventRightMouseDown)| CGEventMaskBit(kCGEventRightMouseUp) |
    CGEventMaskBit(kCGEventOtherMouseDown)| CGEventMaskBit(kCGEventOtherMouseUp) |
    CGEventMaskBit(kCGEventScrollWheel);

  // 创建仅监听的全局事件 Tap：
  // kCGHIDEventTap 在 HID 层捕获全局事件；kCGHeadInsertEventTap 使回调尽可能早；
  // kCGEventTapOptionListenOnly 不拦截事件、不改变系统行为。需要辅助功能/输入监控权限。
  g_pid = getpid();
  g_tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, TapCallback, NULL);
  if (g_tap) {
    // 将 Tap 的 RunLoop 源加入主运行循环（CommonModes），并启用 Tap。
    // 之后所有匹配事件由 TapCallback 回调，再通过 g_sink 推送到 Dart。
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(g_tap, true);
  }

  // 返回 nil 表示启动成功；若 g_tap 创建失败当前不向 Dart 报错，可按需扩展错误处理。
  return nil;
}

- (FlutterError*)onCancelWithArguments:(id)args {
  if (g_tap) { CFMachPortInvalidate(g_tap); CFRelease(g_tap); g_tap = NULL; }
  g_sink = nil;
  return nil;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([@"simulateMouse" isEqualToString:call.method]) {
    NSDictionary* a = call.arguments;
    NSString* type = a[@"type"] ?: @"move";
    double x = [a[@"x"] ?: @(0) doubleValue], y = [a[@"y"] ?: @(0) doubleValue];
    NSString* b = a[@"button"] ?: @"left";
    if ([type isEqualToString:@"move"]) {
      CGWarpMouseCursorPosition(CGPointMake(x, y));
    } else {
      CGMouseButton btn = [b isEqualToString:@"right"] ? kCGMouseButtonRight : ([b isEqualToString:@"middle"] ? kCGMouseButtonCenter : kCGMouseButtonLeft);
      CGEventType t = ([type isEqualToString:@"down"] ?
                       (btn==kCGMouseButtonLeft? kCGEventLeftMouseDown : (btn==kCGMouseButtonRight? kCGEventRightMouseDown : kCGEventOtherMouseDown)) :
                       (btn==kCGMouseButtonLeft? kCGEventLeftMouseUp   : (btn==kCGMouseButtonRight? kCGEventRightMouseUp   : kCGEventOtherMouseUp)));
      CGEventRef e = CGEventCreateMouseEvent(NULL, t, CGPointMake(x, y), btn);
      CGEventPost(kCGHIDEventTap, e); CFRelease(e);
    }
    result(nil); return;
  }
  if ([@"simulateKey" isEqualToString:call.method]) {
    NSDictionary* a = call.arguments;
    int keyCode = [a[@"keyCode"] intValue]; BOOL isDown = [a[@"isDown"] boolValue];
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)keyCode, isDown);
    CGEventPost(kCGHIDEventTap, e); CFRelease(e);
    result(nil); return;
  }
  if ([@"setInterceptedKeys" isEqualToString:call.method]) {
    id args = call.arguments;
    NSArray* keys = nil;
    if ([args isKindOfClass:[NSArray class]]) {
      keys = (NSArray*)args;
    } else {
      keys = @[];
    }
    if (!g_block) g_block = [NSMutableSet set];
    [g_block removeAllObjects];
    for (id n in keys) {
      if ([n isKindOfClass:[NSNumber class]]) { [g_block addObject:(NSNumber*)n]; }
      else if ([n isKindOfClass:[NSString class]]) { [g_block addObject:@([(NSString*)n intValue])]; }
    }
    result(nil); return;
  }
  if ([@"clearInterceptedKeys" isEqualToString:call.method]) { g_block = nil; result(nil); return; }
  if ([@"setInterceptAllKeys" isEqualToString:call.method]) {
    id args = call.arguments; BOOL en = NO;
    if ([args isKindOfClass:[NSNumber class]]) en = [((NSNumber*)args) boolValue];
    else if ([args isKindOfClass:[NSDictionary class]]) en = [((NSDictionary*)args)[@"enabled"] boolValue];
    g_intercept_all_keys = en; result(nil); return;
  }
  if ([@"setInterceptAllMouse" isEqualToString:call.method]) {
    id args = call.arguments; BOOL en = NO;
    if ([args isKindOfClass:[NSNumber class]]) en = [((NSNumber*)args) boolValue];
    else if ([args isKindOfClass:[NSDictionary class]]) en = [((NSDictionary*)args)[@"enabled"] boolValue];
    g_intercept_all_mouse = en; result(nil); return;
  }
  if ([@"getScreenSize" isEqualToString:call.method]) {
    NSScreen* s = [NSScreen mainScreen];
    CGFloat w = s.frame.size.width;
    CGFloat h = s.frame.size.height;
    result(@{ @"width": @(w), @"height": @(h) });
    return;
  }
  result(FlutterMethodNotImplemented);
}
@end