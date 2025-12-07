import 'package:flutter/material.dart';
import 'dart:async';
import 'package:followmotion/followmotion.dart' as fm;
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'FollowMotion Example',
      home: HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('首页')),
      body: Center(
        child: ElevatedButton(
          onPressed: () async {
            final size = await fm.getScreenSize();
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => SimWindowPage(screenSize: size)),
            );
          },
          child: const Text('开始模拟'),
        ),
      ),
    );
  }
}

class SimWindowPage extends StatefulWidget {
  const SimWindowPage({super.key, required this.screenSize});
  final Size screenSize;
  @override
  State<SimWindowPage> createState() => _SimWindowPageState();
}

class _RecordingItem {
  fm.EventRecorder recorder;
  String? json;
  bool showJson;
  _RecordingItem(this.recorder, [this.json, this.showJson=false]);
}

class _SimWindowPageState extends State<SimWindowPage> {
  StreamSubscription? _sub;
  final double scale = 0.25;
  Offset overlayPos = const Offset(50, 50);
  Offset? cursorInOverlay;
  bool draggingOverlay = false;
  fm.EventRecorder? _recorder;
  final List<_RecordingItem> _recordings = [];
  bool _recording = false;
  int _qPressCount = 0;
  DateTime? _qFirstAt;
  bool _interceptKeys = true;
  bool _interceptMouse = true;
  final List<String> _events = [];
  final TextEditingController _keysController = TextEditingController(text: '12,13');
  bool _includeInjected = false;
  double _replaySpeed = 1.0;

  Size get viewSize => Size(widget.screenSize.width * scale, widget.screenSize.height * scale);

  @override
  void initState() {
    super.initState();
    fm.setLogListener((level, message) {
      debugPrint('[${level.name}] $message');
    });
    fm.setInterceptedKeys([12, 13]);
    fm.setInterceptAllKeys(_interceptKeys);
    fm.setInterceptAllMouse(_interceptMouse);
    _sub = fm.globalInputEvents().listen((ev) {
      if (ev is fm.MouseEvent) {
        setState(() {
          cursorInOverlay = Offset(ev.x * scale, ev.y * scale);
          _events.add('mouse ${ev.type} ${ev.button} x=${ev.x.toInt()} y=${ev.y.toInt()}');
          if (_events.length > 100) _events.removeAt(0);
        });
      } else if (ev is fm.KeyEvent) {
        setState(() {
          _events.add('key code=${ev.keyCode} down=${ev.isDown} injected=${ev.injected}');
          if (_events.length > 100) _events.removeAt(0);
        });
        if (!ev.injected && ev.keyCode == 12) {
          if (ev.isDown) {
            final now = DateTime.now();
            if (_qFirstAt == null || now.difference(_qFirstAt!) > const Duration(seconds: 5)) {
              _qFirstAt = now;
              _qPressCount = 0;
            }
            _qPressCount++;
            final elapsed = now.difference(_qFirstAt!);
            if (_qPressCount >= 10 && elapsed <= const Duration(seconds: 5)) {
              _qPressCount = 0;
              _qFirstAt = null;
              fm.setInterceptAllKeys(false);
              fm.setInterceptAllMouse(false);
              fm.clearInterceptedKeys();
              setState(() { _interceptKeys = false; _interceptMouse = false; });
            }
          }
        } else if (!ev.injected && ev.isDown) {
          _qPressCount = 0;
          _qFirstAt = null;
        }
        if (!ev.injected && (ev.keyCode == 12 || ev.keyCode == 13)) {
          final to = ev.keyCode == 12 ? 13 : 12;
          fm.simulateKey(keyCode: to, isDown: ev.isDown);
        }
      } else if (ev is fm.WheelEvent) {
        setState(() {
          _events.add('wheel dy=${ev.deltaY}');
          if (_events.length > 100) _events.removeAt(0);
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _keysController.dispose();
    super.dispose();
  }

  Future<void> _sendMouseFromLocal(Offset local, {String type = 'move', String button = 'left'}) async {
    final realX = local.dx / scale;
    final realY = local.dy / scale;
    await fm.simulateMouse(type: type, x: realX, y: realY, button: button);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(children: [
        Positioned(
          left: overlayPos.dx,
          top: overlayPos.dy,
          child: GestureDetector(
            onPanStart: (d) async {
              final local = d.localPosition;
              await _sendMouseFromLocal(local, type: 'down');
            },
            onPanUpdate: (d) async {
              final local = d.localPosition;
              await _sendMouseFromLocal(local, type: 'move');
            },
            onPanEnd: (_) async {
              if (cursorInOverlay != null) {
                await _sendMouseFromLocal(cursorInOverlay!, type: 'up');
              }
            },
            onLongPressStart: (d) {
              draggingOverlay = true;
            },
            onLongPressMoveUpdate: (d) {
              setState(() {
                overlayPos += d.offsetFromOrigin;
              });
            },
            onLongPressEnd: (_) {
              draggingOverlay = false;
            },
            child: Container(
              width: viewSize.width,
              height: viewSize.height,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.05),
                border: Border.all(color: Colors.blueAccent, width: 2),
              ),
              child: CustomPaint(
                painter: _CursorPainter(cursorInOverlay),
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          top: 16,
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const HomePage()),
            ),
            child: const Text('退出模拟'),
          ),
        ),
        Positioned(
          right: 16,
          top: 64,
          child: SizedBox(
            width: 340,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () async {
                        if (!_recording) {
                          _recorder = fm.startRecording(includeInjected: _includeInjected);
                          setState(() { _recording = true; });
                        } else {
                          final r = _recorder!;
                          await r.stop();
                          final json = r.toJson();
                          setState(() {
                            _recordings.add(_RecordingItem(r, json, false));
                            _recording = false;
                          });
                        }
                      },
                      child: Text(_recording ? '停止并保存' : '开始录制'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: SwitchListTile(
                      title: const Text('拦截所有键盘'),
                      value: _interceptKeys,
                      onChanged: (v) {
                        setState(() { _interceptKeys = v; });
                        fm.setInterceptAllKeys(v);
                      },
                    ),
                  ),
                  Expanded(
                    child: SwitchListTile(
                      title: const Text('拦截所有鼠标'),
                      value: _interceptMouse,
                      onChanged: (v) {
                        setState(() { _interceptMouse = v; });
                        fm.setInterceptAllMouse(v);
                      },
                    ),
                  ),
                ]),
                Row(children: [
                  TextButton(
                    onPressed: () { fm.setInterceptedKeys([12, 13]); },
                    child: const Text('拦截Q/W'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () { fm.clearInterceptedKeys(); },
                    child: const Text('清空拦截键'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      final cx = widget.screenSize.width / 2;
                      final cy = widget.screenSize.height / 2;
                      await fm.simulateMouse(type: 'move', x: cx, y: cy);
                    },
                    child: const Text('鼠标移动到中心'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      final x = widget.screenSize.width / 2;
                      final y = widget.screenSize.height / 2;
                      await fm.simulateMouse(type: 'down', x: x, y: y);
                      await fm.simulateMouse(type: 'up', x: x, y: y);
                    },
                    child: const Text('鼠标左键单击中心'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      await fm.simulateKey(keyCode: 12, isDown: true);
                      await fm.simulateKey(keyCode: 12, isDown: false);
                    },
                    child: const Text('模拟Q按下/抬起'),
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  const Text('重放速度'),
                  Expanded(child: Slider(value: _replaySpeed, min: 0.25, max: 3.0, divisions: 11, label: '${_replaySpeed.toStringAsFixed(2)}x', onChanged: (v) { setState(() { _replaySpeed = v; }); })),
                  Text('${_replaySpeed.toStringAsFixed(2)}x'),
                ]),
                SwitchListTile(title: const Text('录制包含注入事件'), value: _includeInjected, onChanged: (v) { setState(() { _includeInjected = v; }); }),
                Row(children: [
                  Expanded(child: TextField(controller: _keysController, decoration: const InputDecoration(labelText: '拦截键列表(逗号分隔)', border: OutlineInputBorder()))),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: () { final parts = _keysController.text.split(','); final codes = <int>[]; for (final p in parts) { final n = int.tryParse(p.trim()); if (n != null) codes.add(n); } fm.setInterceptedKeys(codes); }, child: const Text('应用拦截键')),
                ]),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 160),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _events.length,
                    itemBuilder: (context, i) => Text(_events[i]),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 300),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _recordings.length,
                    itemBuilder: (context, i) {
                      final rec = _recordings[i];
                      final cnt = rec.recorder.events.length;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text('录制 #$i 事件数: $cnt')),
                              TextButton(
                                onPressed: () { setState(() { _recordings.removeAt(i); }); },
                                child: const Text('删除'),
                              ),
                              TextButton(
                                onPressed: () { setState(() { rec.showJson = !rec.showJson; rec.json ??= rec.recorder.toJson(); }); },
                                child: const Text('序列化'),
                              ),
                              TextButton(
                                onPressed: () async { await fm.replayRecording(rec.recorder, speed: _replaySpeed); },
                                child: const Text('重放'),
                              ),
                            ],
                          ),
                          if (rec.showJson)
                            Container(
                              padding: const EdgeInsets.all(8),
                              color: Colors.black12,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SelectableText(rec.json ?? ''),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: () { final text = rec.json ?? ''; Clipboard.setData(ClipboardData(text: text)); },
                                      child: const Text('复制'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

class _CursorPainter extends CustomPainter {
  _CursorPainter(this.pos);
  final Offset? pos;
  @override
  void paint(Canvas canvas, Size size) {
    if (pos == null) return;
    final paint = Paint()..color = Colors.red..style = PaintingStyle.fill;
    canvas.drawCircle(pos!, 6, paint);
  }
  @override
  bool shouldRepaint(covariant _CursorPainter old) => old.pos != pos;
}