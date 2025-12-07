#include "global_input_plugin.h"
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>
#include <X11/extensions/XTest.h>
#include <thread>
#include <atomic>
#include <vector>

static std::atomic<bool> g_run{false};
static std::unique_ptr<FlEventSink> g_sink;
static std::vector<int> g_blocked;

static void emit_event(FlEventSink* sink, FlValue* map) {
  if (sink) fl_event_sink_success(sink, map);
}

static void listen_thread(FlEventSink* sink) {
  Display* dpy = XOpenDisplay(nullptr);
  if (!dpy) return;
  int xi_opcode, ev, err;
  if (!XQueryExtension(dpy, "XInputExtension", &xi_opcode, &ev, &err)) { XCloseDisplay(dpy); return; }
  Window root = DefaultRootWindow(dpy);
  XIEventMask mask; unsigned char m[3] = {0};
  mask.deviceid = XIAllMasterDevices; mask.mask_len = sizeof(m); mask.mask = m;
  XISetMask(m, XI_RawKeyPress); XISetMask(m, XI_RawKeyRelease);
  XISetMask(m, XI_RawButtonPress); XISetMask(m, XI_RawButtonRelease);
  XISetMask(m, XI_RawMotion);
  XISelectEvents(dpy, root, &mask, 1);
  XFlush(dpy);

  while (g_run.load()) {
    XEvent ev; XGenericEventCookie* cookie = &ev.xcookie;
    XNextEvent(dpy, &ev);
    if (ev.xcookie.type == GenericEvent && ev.xcookie.extension == xi_opcode && XGetEventData(dpy, cookie)) {
      if (cookie->evtype == XI_RawKeyPress || cookie->evtype == XI_RawKeyRelease) {
        XIRawEvent* e = (XIRawEvent*)cookie->data;
        FlValue* m = fl_value_new_map();
        fl_value_set_string_take(m, "kind", fl_value_new_string("key"));
        fl_value_set_string_take(m, "keyCode", fl_value_new_int(e->detail));
        fl_value_set_string_take(m, "isDown", fl_value_new_bool(cookie->evtype == XI_RawKeyPress));
        emit_event(sink, m);
      } else if (cookie->evtype == XI_RawButtonPress || cookie->evtype == XI_RawButtonRelease) {
        XIRawEvent* e = (XIRawEvent*)cookie->data;
        if (e->detail == 4 || e->detail == 5) {
          int dy = (e->detail == 4) ? 1 : -1;
          FlValue* m = fl_value_new_map();
          fl_value_set_string_take(m, "kind", fl_value_new_string("wheel"));
          fl_value_set_string_take(m, "deltaY", fl_value_new_int(dy));
          emit_event(sink, m);
        } else {
          const char* btn = "left"; if (e->detail == 3) btn = "right"; else if (e->detail == 2) btn = "middle";
          Window r, child; int rx, ry, wx, wy; unsigned int mask;
          XQueryPointer(dpy, root, &r, &child, &rx, &ry, &wx, &wy, &mask);
          FlValue* m = fl_value_new_map();
          fl_value_set_string_take(m, "kind", fl_value_new_string("mouse"));
          fl_value_set_string_take(m, "type", fl_value_new_string(cookie->evtype == XI_RawButtonPress ? "down" : "up"));
          fl_value_set_string_take(m, "button", fl_value_new_string(btn));
          fl_value_set_string_take(m, "x", fl_value_new_int(rx));
          fl_value_set_string_take(m, "y", fl_value_new_int(ry));
          emit_event(sink, m);
        }
      } else if (cookie->evtype == XI_RawMotion) {
        Window r, child; int rx, ry, wx, wy; unsigned int mask;
        XQueryPointer(dpy, root, &r, &child, &rx, &ry, &wx, &wy, &mask);
        FlValue* m = fl_value_new_map();
        fl_value_set_string_take(m, "kind", fl_value_new_string("mouse"));
        fl_value_set_string_take(m, "type", fl_value_new_string("move"));
        fl_value_set_string_take(m, "x", fl_value_new_int(rx));
        fl_value_set_string_take(m, "y", fl_value_new_int(ry));
        emit_event(sink, m);
      }
      XFreeEventData(dpy, cookie);
    }
  }
  XCloseDisplay(dpy);
}

static void simulate_mouse(FlValue* args) {
  Display* dpy = XOpenDisplay(nullptr); if (!dpy) return;
  FlValue* vType = fl_value_lookup_string(args, "type");
  const gchar* type = vType ? fl_value_get_string(vType) : "move";
  if (g_strcmp0(type, "move") == 0) {
    FlValue* vx = fl_value_lookup_string(args, "x");
    FlValue* vy = fl_value_lookup_string(args, "y");
    FlValue* vdx = fl_value_lookup_string(args, "dx");
    FlValue* vdy = fl_value_lookup_string(args, "dy");
    if (vx && vy) {
      XWarpPointer(dpy, None, DefaultRootWindow(dpy), 0,0,0,0, fl_value_get_int(vx), fl_value_get_int(vy));
      XFlush(dpy);
    } else {
      XTestFakeRelativeMotionEvent(dpy, vdx?fl_value_get_int(vdx):0, vdy?fl_value_get_int(vdy):0, CurrentTime);
      XFlush(dpy);
    }
  } else {
    const gchar* btnStr = "left";
    FlValue* vb = fl_value_lookup_string(args, "button"); if (vb) btnStr = fl_value_get_string(vb);
    int btn = 1; if (!g_strcmp0(btnStr,"right")) btn=3; else if (!g_strcmp0(btnStr,"middle")) btn=2;
    gboolean press = !g_strcmp0(type, "down");
    XTestFakeButtonEvent(dpy, btn, press, CurrentTime); XFlush(dpy);
  }
  XCloseDisplay(dpy);
}

static void simulate_key(FlValue* args) {
  Display* dpy = XOpenDisplay(nullptr); if (!dpy) return;
  int keyCode = fl_value_get_int(fl_value_lookup_string(args, "keyCode"));
  bool isDown = fl_value_get_bool(fl_value_lookup_string(args, "isDown"));
  XTestFakeKeyEvent(dpy, keyCode, isDown ? True : False, CurrentTime);
  XFlush(dpy); XCloseDisplay(dpy);
}

static void on_method_call(FlMethodChannel* ch, FlMethodCall* call, gpointer) {
  const gchar* name = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (!g_strcmp0(name, "simulateMouse")) { simulate_mouse(args); fl_method_call_respond_success(call, nullptr, nullptr); return; }
  if (!g_strcmp0(name, "simulateKey"))   { simulate_key(args);   fl_method_call_respond_success(call, nullptr, nullptr); return; }
  if (!g_strcmp0(name, "setInterceptedKeys")) { fl_method_call_respond_success(call, nullptr, nullptr); return; }
  if (!g_strcmp0(name, "setInterceptAllKeys")) { fl_method_call_respond_success(call, nullptr, nullptr); return; }
  if (!g_strcmp0(name, "setInterceptAllMouse")) { fl_method_call_respond_success(call, nullptr, nullptr); return; }
  fl_method_call_respond_not_implemented(call, nullptr);"setBlockedKeys")) {
    g_blocked.clear(); int n = fl_value_get_length(args);
    for (int i = 0; i < n; ++i) { FlValue* v = fl_value_get_list_value(args, i); if (v) g_blocked.push_back(fl_value_get_int(v)); }
    fl_method_call_respond_success(call, nullptr, nullptr); return;
  }
  if (!g_strcmp0(name, "clearBlockedKeys")) { g_blocked.clear(); fl_method_call_respond_success(call, nullptr, nullptr); return; }
  fl_method_call_respond_not_implemented(call, nullptr);
}

static FlEventSink* start_stream() {
  g_run.store(true);
  auto sink = fl_event_sink_new();
  g_sink.reset(sink);
  std::thread(listen_thread, sink).detach();
  return sink;
}

static void stop_stream() {
  g_run.store(false);
  g_sink.reset();
}

void register_global_input_plugin(FlBinaryMessenger* messenger) {
  auto codec = fl_standard_method_codec_new();
  FlMethodChannel* mc = fl_method_channel_new(messenger, "input_simulator", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(mc, on_method_call, nullptr, nullptr);

  FlEventChannel* ec = fl_event_channel_new(messenger, "global_input_events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
    ec,
    [](FlEventChannel*, FlValue*, gpointer){ return start_stream(); },
    [](FlEventChannel*, FlValue*, gpointer){ stop_stream(); }
  );
}