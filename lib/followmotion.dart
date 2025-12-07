library followmotion;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

abstract class GlobalInputEvent {
  Map<String, dynamic> toMap();
  static GlobalInputEvent fromMap(Map<String, dynamic> m) {
    final k = m['kind'] as String? ?? '';
    if (k == 'key') return KeyEvent.fromMap(m);
    if (k == 'mouse') return MouseEvent.fromMap(m);
    if (k == 'wheel') return WheelEvent.fromMap(m);
    return WheelEvent(0);
  }
}
class KeyEvent extends GlobalInputEvent {
  final int keyCode; final bool isDown; final bool injected;
  KeyEvent(this.keyCode, this.isDown, this.injected);
  @override
  Map<String, dynamic> toMap() => {
    'kind': 'key', 'keyCode': keyCode, 'isDown': isDown, 'injected': injected,
  };
  static KeyEvent fromMap(Map<String, dynamic> m) {
    return KeyEvent((m['keyCode'] as num).toInt(), m['isDown'] as bool, (m['injected'] as bool?) ?? false);
  }
}
class MouseEvent extends GlobalInputEvent {
  final String type; final String button; final double x; final double y;
  MouseEvent({required this.type, required this.button, required this.x, required this.y});
  @override
  Map<String, dynamic> toMap() => {
    'kind': 'mouse', 'type': type, 'button': button, 'x': x, 'y': y,
  };
  static MouseEvent fromMap(Map<String, dynamic> m) {
    return MouseEvent(
      type: (m['type'] as String?) ?? 'move',
      button: (m['button'] as String?) ?? 'left',
      x: (m['x'] as num?)?.toDouble() ?? 0.0,
      y: (m['y'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
class WheelEvent extends GlobalInputEvent {
  final int deltaY; WheelEvent(this.deltaY);
  @override
  Map<String, dynamic> toMap() => {
    'kind': 'wheel', 'deltaY': deltaY,
  };
  static WheelEvent fromMap(Map<String, dynamic> m) {
    return WheelEvent((m['deltaY'] as num?)?.toInt() ?? 0);
  }
}
enum LogLevel { debug, info, warning, error }
typedef LogListener = void Function(LogLevel level, String message);

const MethodChannel _simulator = MethodChannel('input_simulator');
const EventChannel _globalEvents = EventChannel('global_input_events');
LogListener? _logListener;

void setLogListener(LogListener? listener) { _logListener = listener; }
void _log(LogLevel level, String message) { final l = _logListener; if (l != null) l(level, message); }

Stream<GlobalInputEvent> globalInputEvents() {
  return _globalEvents.receiveBroadcastStream().map(_toEvent);
}

Stream<dynamic> globalEvents() {
  return _globalEvents.receiveBroadcastStream();
}

GlobalInputEvent _toEvent(dynamic e) {
  final m = Map<String, dynamic>.from(e as Map);
  _log(LogLevel.debug, 'event $m');
  return GlobalInputEvent.fromMap(m);
}

Future<void> simulateMouse({
  required String type,
  required double x,
  required double y,
  String button = 'left',
}) async {
  _log(LogLevel.info, 'simulateMouse type=$type x=$x y=$y button=$button');
  await _simulator.invokeMethod('simulateMouse', {
    'type': type,
    'x': x,
    'y': y,
    'button': button,
  });
}

Future<void> simulateKey({
  required int keyCode,
  required bool isDown,
}) async {
  _log(LogLevel.info, 'simulateKey code=$keyCode isDown=$isDown');
  await _simulator.invokeMethod('simulateKey', {
    'keyCode': keyCode,
    'isDown': isDown,
  });
}

Future<void> setInterceptedKeys(List<int> codes) async {
  await _simulator.invokeMethod('setInterceptedKeys', codes);
}

Future<void> setInterceptAllKeys(bool enabled) async {
  await _simulator.invokeMethod('setInterceptAllKeys', enabled);
}

Future<void> setInterceptAllMouse(bool enabled) async {
  await _simulator.invokeMethod('setInterceptAllMouse', enabled);
}

Future<void> clearInterceptedKeys() async {
  await _simulator.invokeMethod('clearInterceptedKeys');
}

Future<Size> getScreenSize() async {
  final m = await _simulator.invokeMethod('getScreenSize');
  final w = (m['width'] as num).toDouble();
  final h = (m['height'] as num).toDouble();
  return Size(w, h);
}


class RecordedEvent {
  final Duration offset;
  final GlobalInputEvent event;
  RecordedEvent(this.offset, this.event);
  Map<String, dynamic> toMap() => {
    'offsetUs': offset.inMicroseconds,
    'event': event.toMap(),
  };
  static RecordedEvent fromMap(Map<String, dynamic> m) {
    final off = Duration(microseconds: (m['offsetUs'] as num).toInt());
    final ev = GlobalInputEvent.fromMap(Map<String, dynamic>.from(m['event'] as Map));
    return RecordedEvent(off, ev);
  }
}

class EventRecorder {
  final bool includeInjected;
  EventRecorder({this.includeInjected = false});
  final List<RecordedEvent> _events = [];
  DateTime? _start;
  StreamSubscription<GlobalInputEvent>? _sub;
  bool get isRecording => _sub != null;
  List<RecordedEvent> get events => List.unmodifiable(_events);
  void start() {
    if (_sub != null) return;
    _events.clear();
    _start = DateTime.now();
    _sub = globalInputEvents().listen((e) {
      if (!includeInjected && e is KeyEvent && e.injected) return;
      final s = _start; if (s == null) return;
      final off = DateTime.now().difference(s);
      _events.add(RecordedEvent(off, e));
    });
  }

  Future<List<RecordedEvent>> stop() async {
    await _sub?.cancel();
    _sub = null;
    return List.unmodifiable(_events);
  }

  Future<void> play({double speed = 1.0}) async {
    if (_events.isEmpty) return;
    Duration last = Duration.zero;
    for (final re in _events) {
      final d = re.offset - last;
      last = re.offset;
      final us = (d.inMicroseconds / speed).round();
      if (us > 0) await Future.delayed(Duration(microseconds: us));
      final ev = re.event;
      if (ev is KeyEvent) {
        await simulateKey(keyCode: ev.keyCode, isDown: ev.isDown);
      } else if (ev is MouseEvent) {
        await simulateMouse(type: ev.type, x: ev.x, y: ev.y, button: ev.button);
      }
    }
  }

  void clear() { _events.clear(); }
  
  String toJson() => jsonEncode(_events.map((e) => e.toMap()).toList());

  static EventRecorder fromJson(String s, {bool includeInjected = false}) {
    final list = jsonDecode(s) as List<dynamic>;
    return fromList(list, includeInjected: includeInjected);
  }

  static EventRecorder fromList(List<dynamic> list, {bool includeInjected = false}) {
    final r = EventRecorder(includeInjected: includeInjected);
    r._events.clear();
    for (final item in list) {
      final m = Map<String, dynamic>.from(item as Map);
      r._events.add(RecordedEvent.fromMap(m));
    }
    r._start = null;
    return r;
  }
}

EventRecorder createEventRecorder({bool includeInjected = false}) => EventRecorder(includeInjected: includeInjected);
EventRecorder startRecording({bool includeInjected = false}) { final r = EventRecorder(includeInjected: includeInjected); r.start(); return r; }
Future<void> replayRecording(EventRecorder r, {double speed = 1.0}) => r.play(speed: speed);
EventRecorder eventRecorderFromJson(String s, {bool includeInjected = false}) => EventRecorder.fromJson(s, includeInjected: includeInjected);
