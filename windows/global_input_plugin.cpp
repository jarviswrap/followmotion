#include "global_input_plugin.h"
#include <Windows.h>
#include <memory>
#include <mutex>
#include <unordered_set>

static HHOOK g_kb_hook = nullptr;
static HHOOK g_ms_hook = nullptr;
static std::mutex g_sink_mutex;
static std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> g_sink;
static std::unordered_set<int> g_blocked;

static void emit_event(const flutter::EncodableMap& m) {
  std::lock_guard<std::mutex> lock(g_sink_mutex);
  if (g_sink) g_sink->Success(flutter::EncodableValue(m));
}

static LRESULT CALLBACK KbProc(int nCode, WPARAM wParam, LPARAM lParam) {
  if (nCode == HC_ACTION) {
    const KBDLLHOOKSTRUCT* k = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
    bool down = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN);
    bool up   = (wParam == WM_KEYUP   || wParam == WM_SYSKEYUP);
    if (down || up) {
      if (g_blocked.find((int)k->vkCode) != g_blocked.end()) {
        emit_event({
          {flutter::EncodableValue("kind"), flutter::EncodableValue("key")},
          {flutter::EncodableValue("keyCode"), flutter::EncodableValue((int)k->vkCode)},
          {flutter::EncodableValue("isDown"), flutter::EncodableValue(down)}
        });
        return 1;
      }
      emit_event({
        {flutter::EncodableValue("kind"), flutter::EncodableValue("key")},
        {flutter::EncodableValue("keyCode"), flutter::EncodableValue((int)k->vkCode)},
        {flutter::EncodableValue("isDown"), flutter::EncodableValue(down)}
      });
    }
  }
  return CallNextHookEx(g_kb_hook, nCode, wParam, lParam);
}

static LRESULT CALLBACK MsProc(int nCode, WPARAM wParam, LPARAM lParam) {
  if (nCode == HC_ACTION) {
    const MSLLHOOKSTRUCT* m = reinterpret_cast<MSLLHOOKSTRUCT*>(lParam);
    const char* type = nullptr; const char* btn = "left";
    switch (wParam) {
      case WM_MOUSEMOVE: type = "move"; break;
      case WM_LBUTTONDOWN: type = "down"; btn = "left"; break;
      case WM_LBUTTONUP:   type = "up";   btn = "left"; break;
      case WM_RBUTTONDOWN: type = "down"; btn = "right"; break;
      case WM_RBUTTONUP:   type = "up";   btn = "right"; break;
      case WM_MBUTTONDOWN: type = "down"; btn = "middle"; break;
      case WM_MBUTTONUP:   type = "up";   btn = "middle"; break;
      case WM_MOUSEWHEEL:
        emit_event({
          {flutter::EncodableValue("kind"), flutter::EncodableValue("wheel")},
          {flutter::EncodableValue("deltaY"), flutter::EncodableValue((int)(GET_WHEEL_DELTA_WPARAM(m->mouseData) / WHEEL_DELTA))},
        });
        return CallNextHookEx(g_ms_hook, nCode, wParam, lParam);
      default: break;
    }
    if (type) {
      emit_event({
        {flutter::EncodableValue("kind"), flutter::EncodableValue("mouse")},
        {flutter::EncodableValue("type"), flutter::EncodableValue(type)},
        {flutter::EncodableValue("button"), flutter::EncodableValue(btn)},
        {flutter::EncodableValue("x"), flutter::EncodableValue((int)m->pt.x)},
        {flutter::EncodableValue("y"), flutter::EncodableValue((int)m->pt.y)},
      });
    }
  }
  return CallNextHookEx(g_ms_hook, nCode, wParam, lParam);
}

static void start_hooks() {
  g_kb_hook = SetWindowsHookExW(WH_KEYBOARD_LL, KbProc, GetModuleHandleW(nullptr), 0);
  g_ms_hook = SetWindowsHookExW(WH_MOUSE_LL, MsProc, GetModuleHandleW(nullptr), 0);
}

static void stop_hooks() {
  if (g_kb_hook) { UnhookWindowsHookEx(g_kb_hook); g_kb_hook = nullptr; }
  if (g_ms_hook) { UnhookWindowsHookEx(g_ms_hook); g_ms_hook = nullptr; }
}

static void simulate_mouse(const flutter::EncodableMap& a) {
  INPUT in{}; in.type = INPUT_MOUSE;
  auto itType = a.find(flutter::EncodableValue("type"));
  auto itX = a.find(flutter::EncodableValue("x"));
  auto itY = a.find(flutter::EncodableValue("y"));
  auto itDx= a.find(flutter::EncodableValue("dx"));
  auto itDy= a.find(flutter::EncodableValue("dy"));
  std::string type = std::get<std::string>(itType->second);
  if (type == "move") {
    if (itX != a.end() && itY != a.end()) {
      int sx = GetSystemMetrics(SM_CXSCREEN), sy = GetSystemMetrics(SM_CYSCREEN);
      double nx = (double)std::get<int>(itX->second) * 65535.0 / (sx - 1);
      double ny = (double)std::get<int>(itY->second) * 65535.0 / (sy - 1);
      in.mi.dx = (LONG)nx; in.mi.dy = (LONG)ny; in.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
    } else {
      in.mi.dx = itDx!=a.end() ? (LONG)std::get<int>(itDx->second) : 0;
      in.mi.dy = itDy!=a.end() ? (LONG)std::get<int>(itDy->second) : 0;
      in.mi.dwFlags = MOUSEEVENTF_MOVE;
    }
  } else {
    std::string btn = "left";
    auto itB = a.find(flutter::EncodableValue("button")); if (itB!=a.end()) btn = std::get<std::string>(itB->second);
    DWORD downF = MOUSEEVENTF_LEFTDOWN, upF = MOUSEEVENTF_LEFTUP;
    if (btn == "right") { downF = MOUSEEVENTF_RIGHTDOWN; upF = MOUSEEVENTF_RIGHTUP; }
    if (btn == "middle"){ downF = MOUSEEVENTF_MIDDLEDOWN; upF = MOUSEEVENTF_MIDDLEUP; }
    in.mi.dwFlags = (type=="down") ? downF : upF;
  }
  SendInput(1, &in, sizeof(INPUT));
}

static void simulate_key(const flutter::EncodableMap& a) {
  INPUT in{}; in.type = INPUT_KEYBOARD;
  in.ki.wVk = (WORD)std::get<int32_t>(a.at(flutter::EncodableValue("keyCode")));
  bool isDown = std::get<bool>(a.at(flutter::EncodableValue("isDown")));
  in.ki.dwFlags = isDown ? 0 : KEYEVENTF_KEYUP;
  SendInput(1, &in, sizeof(INPUT));
}

void RegisterGlobalInputPlugin(flutter::BinaryMessenger* messenger) {
  auto mc = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(messenger, "input_simulator", &flutter::StandardMethodCodec::GetInstance());
  mc->SetMethodCallHandler([](auto& call, auto result){
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (call.method_name() == "simulateMouse" && args) { simulate_mouse(*args); result->Success(); return; }
    if (call.method_name() == "simulateKey"   && args) { simulate_key(*args);   result->Success(); return; }
    if (call.method_name() == "setInterceptedKeys") { result->Success(); return; }
    if (call.method_name() == "setInterceptAllKeys") { result->Success(); return; }
    if (call.method_name() == "setInterceptAllMouse") { result->Success(); return; }
    result->NotImplemented(); == "setBlockedKeys") {
      g_blocked.clear();
      const auto* list = std::get_if<std::vector<flutter::EncodableValue>>(call.arguments());
      if (list) { for (const auto& v : *list) { if (auto p = std::get_if<int>(&v)) g_blocked.insert(*p); } }
      result->Success(); return;
    }
    if (call.method_name() == "clearBlockedKeys") { g_blocked.clear(); result->Success(); return; }
    result->NotImplemented();
  });

  auto ec = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(messenger, "global_input_events", &flutter::StandardMethodCodec::GetInstance());
  auto handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
    [](const flutter::EncodableValue*, std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& sink) {
      { std::lock_guard<std::mutex> lock(g_sink_mutex); g_sink = std::move(sink); }
      start_hooks();
      return nullptr;
    },
    [](const flutter::EncodableValue*) {
      stop_hooks();
      std::lock_guard<std::mutex> lock(g_sink_mutex);
      g_sink.reset();
      return nullptr;
    }
  );
  ec->SetStreamHandler(std::move(handler));
}