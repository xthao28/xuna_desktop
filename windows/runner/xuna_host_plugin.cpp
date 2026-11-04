#include "xuna_host_plugin.h"

#include "xuna_win_apps_browser.h"
#include "xuna_win_common.h"
#include "xuna_win_crypto_media.h"
#include "xuna_win_uia_engine.h"

namespace {

using namespace xuna_win;

void HandleMethodCallOnWorker(
    std::string method, flutter::EncodableMap args,
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  ScopedComInitializer com_scope;

  if (method == "keyEnsure") {
    NCRYPT_PROV_HANDLE prov = 0;
    NCRYPT_KEY_HANDLE key = 0;
    std::vector<uint8_t> pub65;
    bool ok = OpenOrCreateCngP256Key(&prov, &key) &&
              ExportUncompressedPublicKey65(key, &pub65);
    if (key) NCryptFreeObject(key);
    if (prov) NCryptFreeObject(prov);
    if (!ok) {
      result->Error("failed", "CNG P-256 keyEnsure failed");
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("publicKey")] =
        flutter::EncodableValue(Base64Encode(pub65));
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "keySign") {
    const auto* msg_val = FindKey(args, "message");
    const auto* msg_b64 =
        msg_val ? std::get_if<std::string>(msg_val) : nullptr;
    std::vector<uint8_t> message;
    std::vector<uint8_t> sig64;
    if (!msg_b64 || !Base64Decode(*msg_b64, &message) ||
        !SignMessageCngP256(message, &sig64)) {
      result->Error("failed", "CNG P-256 keySign failed");
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("signature")] =
        flutter::EncodableValue(Base64Encode(sig64));
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "media") {
    const auto* cmd_val = FindKey(args, "cmd");
    const auto* cmd_str =
        cmd_val ? std::get_if<std::string>(cmd_val) : nullptr;
    std::string state;
    if (!cmd_str || !HandleMediaCommand(*cmd_str, &state)) {
      result->Error("failed", "Media transport command failed");
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("state")] = flutter::EncodableValue(state);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "volumeSet") {
    const auto* lvl_val = FindKey(args, "level");
    int level = -1;
    if (lvl_val) {
      if (const auto* i32 = std::get_if<int32_t>(lvl_val)) level = *i32;
      if (const auto* i64 = std::get_if<int64_t>(lvl_val))
        level = static_cast<int>(*i64);
    }
    if (level < 0 || level > 100 || !SetMasterVolumeScalar(level)) {
      result->Error("failed", "CoreAudio SetMasterVolumeLevelScalar failed");
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("level")] = flutter::EncodableValue(level);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "nowPlaying") {
    std::vector<std::string> players;
    const auto* pl_val = FindKey(args, "players");
    if (pl_val) {
      if (const auto* list = std::get_if<flutter::EncodableList>(pl_val)) {
        for (const auto& item : *list) {
          if (const auto* s = std::get_if<std::string>(&item)) {
            players.push_back(*s);
          }
        }
      }
    }
    flutter::EncodableMap out;
    HandleNowPlaying(players, &out);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "appLaunch" || method == "workflowRun") {
    const auto* kind_val = FindKey(args, "kind");
    const auto* target_val = FindKey(args, "target");
    const auto* kind_str =
        kind_val ? std::get_if<std::string>(kind_val) : nullptr;
    const auto* target_str =
        target_val ? std::get_if<std::string>(target_val) : nullptr;
    if (!kind_str || !target_str ||
        !LaunchAppOrWorkflow(*kind_str, *target_str)) {
      result->Error("failed", "ShellExecuteExW / ActivateApplication failed");
      return;
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap()));
    return;
  }

  if (method == "urlOpen") {
    const auto* url_val = FindKey(args, "url");
    const auto* url_str =
        url_val ? std::get_if<std::string>(url_val) : nullptr;
    if (!url_str || !OpenHttpsUrl(*url_str)) {
      result->Error("failed", "ShellExecuteExW urlOpen failed");
      return;
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap()));
    return;
  }

  if (method == "browserCurrentUrl") {
    const auto* br_val = FindKey(args, "browser");
    const auto* br_str = br_val ? std::get_if<std::string>(br_val) : nullptr;
    std::string req_browser = br_str ? *br_str : "auto";
    std::string active_url;
    std::string resolved_browser;
    if (!QueryBrowserCurrentUrlUia(req_browser, &active_url,
                                   &resolved_browser)) {
      result->Error("invalid_args",
                    "No active https:// browser tab found via UIA");
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("url")] = flutter::EncodableValue(active_url);
    out[flutter::EncodableValue("browser")] =
        flutter::EncodableValue(resolved_browser);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "permissions") {
    flutter::EncodableMap out;
    out[flutter::EncodableValue("accessibility")] =
        flutter::EncodableValue("granted");
    out[flutter::EncodableValue("notifications")] =
        flutter::EncodableValue("granted");
    out[flutter::EncodableValue("automation")] =
        flutter::EncodableValue(flutter::EncodableMap());
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "requestPermission") {
    flutter::EncodableMap out;
    out[flutter::EncodableValue("state")] = flutter::EncodableValue("granted");
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "hostInfo") {
    flutter::EncodableMap out;
    out[flutter::EncodableValue("platform")] =
        flutter::EncodableValue("windows");
    out[flutter::EncodableValue("osVersion")] =
        flutter::EncodableValue(QueryWindowsOsVersion());
    out[flutter::EncodableValue("hostname")] =
        flutter::EncodableValue(QueryHostname());
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "showToast") {
    const auto* title_val = FindKey(args, "title");
    const auto* body_val = FindKey(args, "body");
    if (!body_val) body_val = FindKey(args, "message");
    const auto* title_str =
        title_val ? std::get_if<std::string>(title_val) : nullptr;
    const auto* body_str =
        body_val ? std::get_if<std::string>(body_val) : nullptr;
    std::string title =
        (title_str && !title_str->empty()) ? *title_str : "XUNA";
    std::string body = body_str ? *body_str : "";
    if (!body.empty()) {
      ShowWindowsToast(title, body);
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("shown")] = flutter::EncodableValue(true);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "displayWake") {
    SetThreadExecutionState(ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
    INPUT mouse_wake = {};
    mouse_wake.type = INPUT_MOUSE;
    mouse_wake.mi.dwFlags = MOUSEEVENTF_MOVE;
    SendInput(1, &mouse_wake, sizeof(INPUT));
    flutter::EncodableMap out;
    out[flutter::EncodableValue("awake")] = flutter::EncodableValue(true);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "clipboardReadText") {
    std::string text;
    if (OpenClipboard(nullptr)) {
      HANDLE h_data = GetClipboardData(CF_UNICODETEXT);
      if (h_data != nullptr) {
        const auto* wstr = static_cast<const wchar_t*>(GlobalLock(h_data));
        if (wstr != nullptr) {
          text = TruncateUtf8(WideToUtf8(std::wstring(wstr)), 2400);
          GlobalUnlock(h_data);
        }
      }
      CloseClipboard();
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("text")] = flutter::EncodableValue(text);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "lockScreen") {
    const BOOL locked = LockWorkStation();
    flutter::EncodableMap out;
    out[flutter::EncodableValue("locked")] =
        flutter::EncodableValue(locked != FALSE);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "readActiveWindowContext") {
    int max_chars = 600;
    if (const auto* mc_val = FindKey(args, "maxChars")) {
      if (const auto* i32 = std::get_if<int32_t>(mc_val)) max_chars = *i32;
      if (const auto* i64 = std::get_if<int64_t>(mc_val))
        max_chars = static_cast<int>(*i64);
    }
    if (max_chars < 80) max_chars = 80;
    if (max_chars > 1200) max_chars = 1200;

    HWND hwnd = GetForegroundWindow();
    wchar_t title_buf[512] = {};
    if (hwnd != nullptr) {
      GetWindowTextW(hwnd, title_buf, 512);
    }
    std::string window_title =
        TruncateUtf8(WideToUtf8(std::wstring(title_buf)), 160);

    std::string proc_name = "unknown";
    bool is_elevated = false;
    if (hwnd != nullptr) {
      DWORD pid = 0;
      GetWindowThreadProcessId(hwnd, &pid);
      if (pid != 0) {
        HANDLE h_proc =
            OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (h_proc != nullptr) {
          wchar_t img_path[MAX_PATH] = {};
          DWORD img_len = MAX_PATH;
          if (QueryFullProcessImageNameW(h_proc, 0, img_path, &img_len)) {
            std::wstring full(img_path, img_len);
            size_t slash = full.find_last_of(L"\\/");
            std::wstring base =
                slash != std::wstring::npos ? full.substr(slash + 1) : full;
            proc_name = WideToUtf8(base);
          }
          HANDLE h_tok = nullptr;
          if (OpenProcessToken(h_proc, TOKEN_QUERY, &h_tok) &&
              h_tok != nullptr) {
            TOKEN_ELEVATION elev = {};
            DWORD ret_len = 0;
            if (GetTokenInformation(h_tok, TokenElevation, &elev, sizeof(elev),
                                    &ret_len)) {
              is_elevated = elev.TokenIsElevated != 0;
            }
            CloseHandle(h_tok);
          }
          CloseHandle(h_proc);
        }
      }
    }

    std::string focused_role = "window";
    std::string visible_text;
    IUIAutomation* uia = nullptr;
    if (SUCCEEDED(CoCreateInstance(__uuidof(CUIAutomation), nullptr,
                                   CLSCTX_INPROC_SERVER,
                                   __uuidof(IUIAutomation),
                                   reinterpret_cast<void**>(&uia))) &&
        uia != nullptr) {
      IUIAutomationElement* focused = nullptr;
      if (SUCCEEDED(uia->GetFocusedElement(&focused)) && focused != nullptr) {
        BOOL is_pwd = FALSE;
        focused->get_CurrentIsPassword(&is_pwd);
        BSTR role_bstr = nullptr;
        if (SUCCEEDED(focused->get_CurrentLocalizedControlType(&role_bstr)) &&
            role_bstr != nullptr) {
          focused_role = TruncateUtf8(
              WideToUtf8(std::wstring(role_bstr, SysStringLen(role_bstr))), 40);
          SysFreeString(role_bstr);
        }
        if (!is_pwd) {
          BSTR name_bstr = nullptr;
          if (SUCCEEDED(focused->get_CurrentName(&name_bstr)) &&
              name_bstr != nullptr) {
            visible_text =
                WideToUtf8(std::wstring(name_bstr, SysStringLen(name_bstr)));
            SysFreeString(name_bstr);
          }
          IUIAutomationValuePattern* val_pat = nullptr;
          if (SUCCEEDED(focused->GetCurrentPatternAs(
                  UIA_ValuePatternId, __uuidof(IUIAutomationValuePattern),
                  reinterpret_cast<void**>(&val_pat))) &&
              val_pat != nullptr) {
            BSTR bval = nullptr;
            if (SUCCEEDED(val_pat->get_CurrentValue(&bval)) &&
                bval != nullptr) {
              std::string val_str =
                  WideToUtf8(std::wstring(bval, SysStringLen(bval)));
              SysFreeString(bval);
              if (!val_str.empty()) {
                if (!visible_text.empty()) visible_text += " — ";
                visible_text += val_str;
              }
            }
            val_pat->Release();
          }
        }
        focused->Release();
      }
      uia->Release();
    }

    flutter::EncodableMap out;
    out[flutter::EncodableValue("appName")] =
        flutter::EncodableValue(proc_name);
    out[flutter::EncodableValue("processName")] =
        flutter::EncodableValue(proc_name);
    out[flutter::EncodableValue("windowTitle")] =
        flutter::EncodableValue(window_title);
    out[flutter::EncodableValue("focusedRole")] =
        flutter::EncodableValue(focused_role);
    out[flutter::EncodableValue("visibleText")] =
        flutter::EncodableValue(TruncateUtf8(visible_text, max_chars));
    out[flutter::EncodableValue("isElevated")] =
        flutter::EncodableValue(is_elevated);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "readBrowserPageSummary") {
    const auto* br_val = FindKey(args, "browser");
    const auto* br_str = br_val ? std::get_if<std::string>(br_val) : nullptr;
    std::string req_browser = br_str ? *br_str : "auto";
    int max_chars = 800;
    if (const auto* mc_val = FindKey(args, "maxChars")) {
      if (const auto* i32 = std::get_if<int32_t>(mc_val)) max_chars = *i32;
      if (const auto* i64 = std::get_if<int64_t>(mc_val))
        max_chars = static_cast<int>(*i64);
    }
    if (max_chars < 80) max_chars = 80;
    if (max_chars > 1600) max_chars = 1600;

    std::string active_url;
    std::string resolved_browser;
    if (!QueryBrowserCurrentUrlUia(req_browser, &active_url,
                                   &resolved_browser)) {
      result->Error("invalid_args",
                    "No active https:// browser tab found via UIA");
      return;
    }

    HWND hwnd = GetForegroundWindow();
    wchar_t title_buf[512] = {};
    if (hwnd != nullptr) {
      GetWindowTextW(hwnd, title_buf, 512);
    }
    std::string page_title =
        TruncateUtf8(WideToUtf8(std::wstring(title_buf)), 160);

    flutter::EncodableList headings;
    flutter::EncodableList actions;
    std::string excerpt_accum;
    IUIAutomation* uia = nullptr;
    if (hwnd != nullptr &&
        SUCCEEDED(CoCreateInstance(__uuidof(CUIAutomation), nullptr,
                                   CLSCTX_INPROC_SERVER,
                                   __uuidof(IUIAutomation),
                                   reinterpret_cast<void**>(&uia))) &&
        uia != nullptr) {
      IUIAutomationElement* root = nullptr;
      if (SUCCEEDED(uia->ElementFromHandle(hwnd, &root)) && root != nullptr) {
        IUIAutomationCondition* true_cond = nullptr;
        if (SUCCEEDED(uia->CreateTrueCondition(&true_cond)) &&
            true_cond != nullptr) {
          IUIAutomationElementArray* arr = nullptr;
          if (SUCCEEDED(root->FindAll(TreeScope_Descendants, true_cond, &arr)) &&
              arr != nullptr) {
            int len = 0;
            arr->get_Length(&len);
            for (int i = 0; i < len && i < 200; ++i) {
              IUIAutomationElement* el = nullptr;
              if (SUCCEEDED(arr->GetElement(i, &el)) && el != nullptr) {
                CONTROLTYPEID ctrl_type = 0;
                el->get_CurrentControlType(&ctrl_type);
                BSTR name_bstr = nullptr;
                std::string text;
                if (SUCCEEDED(el->get_CurrentName(&name_bstr)) &&
                    name_bstr != nullptr) {
                  text =
                      WideToUtf8(std::wstring(name_bstr, SysStringLen(name_bstr)));
                  SysFreeString(name_bstr);
                }
                if (!text.empty()) {
                  if (ctrl_type == UIA_TextControlTypeId) {
                    if (headings.size() < 6 && text.size() >= 4 &&
                        text.size() <= 120) {
                      headings.push_back(flutter::EncodableValue(text));
                    }
                    if (static_cast<int>(excerpt_accum.size()) < max_chars) {
                      if (!excerpt_accum.empty()) excerpt_accum += "\n";
                      excerpt_accum += text;
                    }
                  } else if ((ctrl_type == UIA_ButtonControlTypeId ||
                              ctrl_type == UIA_HyperlinkControlTypeId) &&
                             actions.size() < 8) {
                    actions.push_back(
                        flutter::EncodableValue(TruncateUtf8(text, 80)));
                  }
                }
                el->Release();
              }
            }
            arr->Release();
          }
          true_cond->Release();
        }
        root->Release();
      }
      uia->Release();
    }

    if (headings.empty() && !page_title.empty()) {
      headings.push_back(flutter::EncodableValue(page_title));
    }
    if (excerpt_accum.empty()) {
      excerpt_accum = page_title;
    }

    flutter::EncodableMap out;
    out[flutter::EncodableValue("url")] = flutter::EncodableValue(active_url);
    out[flutter::EncodableValue("browser")] =
        flutter::EncodableValue(resolved_browser);
    out[flutter::EncodableValue("title")] = flutter::EncodableValue(page_title);
    out[flutter::EncodableValue("headings")] =
        flutter::EncodableValue(headings);
    out[flutter::EncodableValue("actions")] = flutter::EncodableValue(actions);
    out[flutter::EncodableValue("excerpt")] =
        flutter::EncodableValue(TruncateUtf8(excerpt_accum, max_chars));
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "inspectWindowUiTree") {
    int max_nodes = 35;
    if (const auto* mn_val = FindKey(args, "maxNodes")) {
      if (const auto* i32 = std::get_if<int32_t>(mn_val)) max_nodes = *i32;
      if (const auto* i64 = std::get_if<int64_t>(mn_val))
        max_nodes = static_cast<int>(*i64);
    }
    if (max_nodes < 1) max_nodes = 1;
    if (max_nodes > 80) max_nodes = 80;

    const auto* wt_val = FindKey(args, "windowTitle");
    const auto* wt_str = wt_val ? std::get_if<std::string>(wt_val) : nullptr;
    std::string req_win_title = wt_str ? *wt_str : "";

    HWND hwnd = ResolveTargetWindow(req_win_title, !req_win_title.empty());
    flutter::EncodableList nodes;
    int redacted_count = 0;
    std::string win_title;
    std::string app_name;
    ScanWindowUiTreeToEncodable(hwnd, max_nodes, &nodes, &redacted_count,
                                &win_title, &app_name);

    flutter::EncodableMap out;
    out[flutter::EncodableValue("windowTitle")] =
        flutter::EncodableValue(win_title);
    out[flutter::EncodableValue("appName")] = flutter::EncodableValue(app_name);
    out[flutter::EncodableValue("nodes")] = flutter::EncodableValue(nodes);
    out[flutter::EncodableValue("redactedControlsCount")] =
        flutter::EncodableValue(redacted_count);
    out[flutter::EncodableValue("screenshotBytesUsed")] =
        flutter::EncodableValue(0);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (method == "invokeWindowUiControl") {
    ExecuteInvokeWindowUiControl(args, std::move(result));
    return;
  }

  result->NotImplemented();
}

struct PendingHostCall {
  std::string method;
  flutter::EncodableMap args;
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
};

constexpr size_t kMaxWorkerThreads = 4;
constexpr size_t kMaxPendingCalls = 64;

struct HostWorkerQueueState {
  std::mutex mutex;
  std::deque<PendingHostCall> queue;
  size_t active_workers = 0;
};

HostWorkerQueueState& GetWorkerQueueState() {
  static auto* state = new HostWorkerQueueState();
  return *state;
}

void DrainHostWorkerQueue() {
  auto& state = GetWorkerQueueState();
  while (true) {
    PendingHostCall call;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      if (state.queue.empty()) {
        --state.active_workers;
        return;
      }
      call = std::move(state.queue.front());
      state.queue.pop_front();
    }
    HandleMethodCallOnWorker(std::move(call.method), std::move(call.args),
                             std::move(call.result));
  }
}

void EnqueueHostMethodCall(
    std::string method, flutter::EncodableMap args,
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto& state = GetWorkerQueueState();
  bool spawn_worker = false;
  {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.queue.size() >= kMaxPendingCalls) {
      result->Error("timeout", "Host worker queue is saturated");
      return;
    }
    state.queue.push_back(
        PendingHostCall{std::move(method), std::move(args), std::move(result)});
    if (state.active_workers < kMaxWorkerThreads) {
      ++state.active_workers;
      spawn_worker = true;
    }
  }
  if (spawn_worker) {
    std::thread(DrainHostWorkerQueue).detach();
  }
}

}  // namespace

void RegisterXunaHostPlugin(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "xuna/host",
          &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        flutter::EncodableMap args;
        if (call.arguments()) {
          if (const auto* map =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            args = *map;
          }
        }
        auto shared_result =
            std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
                std::move(result));
        EnqueueHostMethodCall(call.method_name(), std::move(args),
                              std::move(shared_result));
      });

  // Keep the channel alive for the lifetime of the runner process.
  static auto* leaked_channel = channel.release();
  (void)leaked_channel;
}
