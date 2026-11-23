#ifndef RUNNER_XUNA_WIN_WATCH_H_
#define RUNNER_XUNA_WIN_WATCH_H_

#include <tlhelp32.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "xuna_win_apps_browser.h"
#include "xuna_win_common.h"
#include "xuna_win_crypto_media.h"
#include "xuna_win_uia_engine.h"

namespace xuna_win {

struct WatchError {
  std::string flutter_code;
  std::string error_code;
  std::string message;
};

struct WatchSlot {
  std::string watch_id;
  std::string signal;
  std::string key;

  std::mutex state_mu;
  std::string state = "idle";
  uint64_t change_count = 0;
  uint64_t digest_change_count = 0;
  uint64_t last_polled_digest_change_count = 0;
  bool event_driven = true;
  bool fallback_used = false;
  std::string error_code;
  int64_t last_activity_ms = 0;
  bool stopped = false;

  HANDLE stop_event = nullptr;
  HANDLE ready_event = nullptr;
  bool init_ok = false;
  WatchError init_error;

  std::thread worker;

  ~WatchSlot() {
    {
      std::lock_guard<std::mutex> lk(state_mu);
      stopped = true;
    }
    if (stop_event != nullptr) {
      SetEvent(stop_event);
    }
    if (worker.joinable() && worker.get_id() != std::this_thread::get_id()) {
      worker.join();
    }
    if (stop_event != nullptr) {
      CloseHandle(stop_event);
      stop_event = nullptr;
    }
    if (ready_event != nullptr) {
      CloseHandle(ready_event);
      ready_event = nullptr;
    }
  }
};

inline int64_t WatchNowSteadyMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

inline uint64_t FileTimeToUint64(const FILETIME& ft) {
  ULARGE_INTEGER uli;
  uli.LowPart = ft.dwLowDateTime;
  uli.HighPart = ft.dwHighDateTime;
  return uli.QuadPart;
}

inline bool ExtractIntArgWatch(const flutter::EncodableMap& args,
                               const char* key, int64_t* out_val) {
  const auto* val = FindKey(args, key);
  if (!val) return false;
  if (const auto* i32 = std::get_if<int32_t>(val)) {
    *out_val = static_cast<int64_t>(*i32);
    return true;
  }
  if (const auto* i64 = std::get_if<int64_t>(val)) {
    *out_val = *i64;
    return true;
  }
  return false;
}

inline bool ExtractStringArgWatch(const flutter::EncodableMap& args,
                                  const char* key, std::string* out_val) {
  const auto* val = FindKey(args, key);
  if (!val) return false;
  if (const auto* s = std::get_if<std::string>(val)) {
    *out_val = *s;
    return true;
  }
  return false;
}

inline std::string TrimAsciiWatch(const std::string& raw) {
  size_t first = 0;
  while (first < raw.size() &&
         std::isspace(static_cast<unsigned char>(raw[first]))) {
    ++first;
  }
  size_t last = raw.size();
  while (last > first &&
         std::isspace(static_cast<unsigned char>(raw[last - 1]))) {
    --last;
  }
  return raw.substr(first, last - first);
}

inline std::string EvaluateProcessIdleStateWin(double cpu_percent,
                                               bool has_busy_child,
                                               bool was_busy) {
  if (cpu_percent > 8.0 || has_busy_child) {
    return "active";
  }
  if (cpu_percent < 3.0 && !has_busy_child) {
    return "idle";
  }
  return was_busy ? "active" : "idle";
}

inline bool IsSensitiveSegmentWin(const std::string& lower_seg) {
  if (lower_seg.rfind(".env", 0) == 0) {
    return true;
  }
  static const char* kForbidden[] = {
      ".ssh",    ".aws",     ".gnupg",  ".kube",  ".docker",
      ".claude", ".gemini",  ".npmrc",  ".netrc", ".pypirc",
      "appdata", "library",  "keychains",
  };
  for (const char* item : kForbidden) {
    if (lower_seg == item) {
      return true;
    }
  }
  return false;
}

inline bool IsExcludedRelativeFsPathWin(const std::wstring& rel_w) {
  std::string rel = ToLowerAscii(WideToUtf8(rel_w));
  std::vector<std::string> segments;
  std::string cur;
  for (char ch : rel) {
    if (ch == '\\' || ch == '/') {
      if (!cur.empty()) {
        segments.push_back(cur);
        cur.clear();
      }
    } else {
      cur.push_back(ch);
    }
  }
  if (!cur.empty()) {
    segments.push_back(cur);
  }
  for (size_t i = 0; i < segments.size(); ++i) {
    if (IsSensitiveSegmentWin(segments[i])) {
      return true;
    }
    if (segments[i] == ".ds_store") {
      return true;
    }
    if (segments[i] == ".git" && i + 1 < segments.size() &&
        segments[i + 1] == "objects") {
      return true;
    }
  }
  return false;
}

inline bool ValidateWatchWorkspacePathWin(const std::string& raw_path,
                                          std::wstring* out_final_dir,
                                          WatchError* out_err) {
  std::string trimmed = TrimAsciiWatch(raw_path);
  if (trimmed.empty() || trimmed.size() > size_t{1024}) {
    *out_err = {"invalid_args", "invalid_args",
                "Workspace path is empty or too long"};
    return false;
  }
  if (trimmed.find("..") != std::string::npos) {
    *out_err = {"denied", "policy_blocked",
                "Workspace path traversal is blocked"};
    return false;
  }
  for (unsigned char ch : trimmed) {
    if (ch < 0x20 || ch == 0x7F) {
      *out_err = {"invalid_args", "invalid_args",
                  "Workspace path contains control characters"};
      return false;
    }
  }

  std::wstring w_user_profile = GetEnvWide(L"USERPROFILE");
  if (w_user_profile.empty()) {
    *out_err = {"denied", "policy_blocked", "USERPROFILE is unavailable"};
    return false;
  }
  std::wstring home_final;
  if (!ResolveFinalWindowsPath(w_user_profile, &home_final)) {
    *out_err = {"denied", "policy_blocked",
                "Unable to resolve USERPROFILE canonical path"};
    return false;
  }

  std::wstring w_raw = Utf8ToWide(trimmed);
  if (w_raw.empty()) {
    *out_err = {"invalid_args", "invalid_args", "Invalid UTF-8 workspace path"};
    return false;
  }

  std::wstring target_final;
  if (!ResolveFinalWindowsPath(w_raw, &target_final)) {
    // Check if raw path points outside USERPROFILE before reporting not found.
    wchar_t full_buf[4096] = {};
    DWORD full_len =
        GetFullPathNameW(w_raw.c_str(), 4096, full_buf, nullptr);
    std::string home_lower = ToLowerAscii(WideToUtf8(home_final));
    if (!home_lower.empty() && home_lower.back() != '\\') {
      home_lower.push_back('\\');
    }
    if (full_len > 0 && full_len < 4096) {
      std::string cand_lower =
          ToLowerAscii(WideToUtf8(std::wstring(full_buf, full_len)));
      if (cand_lower.rfind(home_lower, 0) != 0) {
        *out_err = {"denied", "policy_blocked",
                    "Workspace path must reside strictly inside USERPROFILE"};
        return false;
      }
    }
    *out_err = {"failed", "workspace_not_found",
                "Workspace directory does not exist"};
    return false;
  }

  DWORD attrs = GetFileAttributesW(target_final.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES ||
      (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0) {
    *out_err = {"failed", "workspace_not_found",
                "Workspace path is not a directory"};
    return false;
  }

  std::string home_lower = ToLowerAscii(WideToUtf8(home_final));
  std::string target_lower = ToLowerAscii(WideToUtf8(target_final));
  while (!home_lower.empty() && home_lower.back() == '\\') {
    home_lower.pop_back();
  }
  while (!target_lower.empty() && target_lower.back() == '\\') {
    target_lower.pop_back();
  }
  std::string home_prefix = home_lower + "\\";
  if (target_lower == home_lower ||
      target_lower.rfind(home_prefix, 0) != 0) {
    *out_err = {"denied", "policy_blocked",
                "Workspace path must reside strictly inside USERPROFILE"};
    return false;
  }

  std::string rel = target_lower.substr(home_prefix.size());
  if (IsExcludedRelativeFsPathWin(Utf8ToWide(rel))) {
    *out_err = {"denied", "policy_blocked",
                "Sensitive directory is excluded from filesystem watching"};
    return false;
  }

  *out_final_dir = target_final;
  return true;
}

struct WindowPidEnumCtx {
  DWORD target_pid = 0;
  std::string target_app_stem_lower;
  HWND found_hwnd = nullptr;
  std::unordered_set<DWORD> matched_pids;
};

inline BOOL CALLBACK WatchEnumVisibleWindowsCb(HWND hwnd, LPARAM lparam) {
  if (!IsWindowVisible(hwnd)) return TRUE;
  auto* ctx = reinterpret_cast<WindowPidEnumCtx*>(lparam);
  DWORD w_pid = 0;
  GetWindowThreadProcessId(hwnd, &w_pid);
  if (w_pid == 0) return TRUE;

  if (ctx->target_pid != 0) {
    if (w_pid == ctx->target_pid && ctx->found_hwnd == nullptr) {
      ctx->found_hwnd = hwnd;
    }
    return TRUE;
  }

  if (!ctx->target_app_stem_lower.empty()) {
    std::string stem = ToLowerAscii(QueryProcessBaseNameForHwnd(hwnd));
    if (!stem.empty() && stem == ctx->target_app_stem_lower) {
      ctx->matched_pids.insert(w_pid);
      if (ctx->found_hwnd == nullptr) {
        ctx->found_hwnd = hwnd;
      }
    }
  }
  return TRUE;
}

inline bool ResolveUiWatchTargetWin(const flutter::EncodableMap& args,
                                    HWND* out_hwnd, DWORD* out_pid,
                                    WatchError* out_err) {
  int64_t raw_pid = 0;
  int64_t raw_win_id = 0;
  std::string raw_app_id;
  bool has_pid = false;
  if (ExtractIntArgWatch(args, "pid", &raw_pid)) {
    if (raw_pid <= 0 || raw_pid > 0x7FFFFFFFLL) {
      *out_err = {"failed", "target_not_found",
                  "Target pid is out of valid range"};
      return false;
    }
    has_pid = true;
  }
  bool has_win =
      ExtractIntArgWatch(args, "windowId", &raw_win_id) && raw_win_id > 0;
  bool has_app = ExtractStringArgWatch(args, "appId", &raw_app_id);
  raw_app_id = TrimAsciiWatch(raw_app_id);
  if (raw_app_id.empty()) has_app = false;

  if (has_app && IsHardDeniedWindowsAppStem(raw_app_id)) {
    *out_err = {"denied", "policy_blocked",
                "Target application is blocked by policy"};
    return false;
  }

  HWND resolved_hwnd = nullptr;
  DWORD resolved_pid = 0;

  if (has_win) {
    resolved_hwnd =
        reinterpret_cast<HWND>(static_cast<uintptr_t>(raw_win_id));
    if (!IsWindow(resolved_hwnd)) {
      *out_err = {"failed", "target_not_found",
                  "Target windowId is not valid"};
      return false;
    }
    GetWindowThreadProcessId(resolved_hwnd, &resolved_pid);
    if (has_pid && resolved_pid != static_cast<DWORD>(raw_pid)) {
      *out_err = {"failed", "target_not_found",
                  "Target windowId does not match pid"};
      return false;
    }
  } else if (has_pid) {
    resolved_pid = static_cast<DWORD>(raw_pid);
    HANDLE h_proc = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                                FALSE, resolved_pid);
    if (h_proc == nullptr) {
      *out_err = {"failed", "target_not_found",
                  "Target pid is unavailable"};
      return false;
    }
    bool alive = (WaitForSingleObject(h_proc, 0) == WAIT_TIMEOUT);
    CloseHandle(h_proc);
    if (!alive) {
      *out_err = {"failed", "target_not_found", "Target pid has exited"};
      return false;
    }
    WindowPidEnumCtx ctx;
    ctx.target_pid = resolved_pid;
    EnumWindows(WatchEnumVisibleWindowsCb, reinterpret_cast<LPARAM>(&ctx));
    resolved_hwnd = ctx.found_hwnd;
    if (resolved_hwnd == nullptr) {
      *out_err = {"failed", "target_not_found",
                  "No visible window found for target pid"};
      return false;
    }
  } else if (has_app) {
    WindowPidEnumCtx ctx;
    std::string stem = ToLowerAscii(raw_app_id);
    if (stem.size() > size_t{4} &&
        stem.compare(stem.size() - 4, 4, ".exe") == 0) {
      stem = stem.substr(0, stem.size() - 4);
    }
    ctx.target_app_stem_lower = stem;
    EnumWindows(WatchEnumVisibleWindowsCb, reinterpret_cast<LPARAM>(&ctx));
    if (ctx.matched_pids.size() != 1 || ctx.found_hwnd == nullptr) {
      *out_err = {"failed", "target_not_found",
                  ctx.matched_pids.empty()
                      ? "No running window matched appId"
                      : "Multiple processes matched appId"};
      return false;
    }
    resolved_hwnd = ctx.found_hwnd;
    resolved_pid = *ctx.matched_pids.begin();
  } else {
    *out_err = {"failed", "target_not_found",
                "Missing pid, windowId, or appId"};
    return false;
  }

  std::string proc_stem = QueryProcessBaseNameForHwnd(resolved_hwnd);
  if ((!proc_stem.empty() && IsHardDeniedWindowsAppStem(proc_stem)) ||
      IsHardDeniedOrElevatedHwnd(resolved_hwnd)) {
    *out_err = {"denied", "policy_blocked",
                "Target window is elevated or blocked by policy"};
    return false;
  }

  *out_hwnd = resolved_hwnd;
  *out_pid = resolved_pid;
  return true;
}

class UiaWatchStructHandler final
    : public IUIAutomationStructureChangedEventHandler {
 public:
  explicit UiaWatchStructHandler(std::shared_ptr<WatchSlot> slot)
      : ref_count_(1), slot_(std::move(slot)) {}

  void Detach() {
    std::lock_guard<std::mutex> lk(mu_);
    slot_.reset();
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&ref_count_));
  }

  ULONG STDMETHODCALLTYPE Release() override {
    LONG next = InterlockedDecrement(&ref_count_);
    if (next <= 0) {
      delete this;
      return 0;
    }
    return static_cast<ULONG>(next);
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppvObject) override {
    if (ppvObject == nullptr) return E_POINTER;
    if (riid == __uuidof(IUnknown) ||
        riid == __uuidof(IUIAutomationStructureChangedEventHandler)) {
      *ppvObject = static_cast<IUIAutomationStructureChangedEventHandler*>(this);
      AddRef();
      return S_OK;
    }
    *ppvObject = nullptr;
    return E_NOINTERFACE;
  }

  HRESULT STDMETHODCALLTYPE HandleStructureChangedEvent(
      IUIAutomationElement* /*sender*/, StructureChangeType /*changeType*/,
      SAFEARRAY* /*runtimeId*/) override {
    std::shared_ptr<WatchSlot> s;
    {
      std::lock_guard<std::mutex> lk(mu_);
      s = slot_;
    }
    if (s) {
      std::lock_guard<std::mutex> slk(s->state_mu);
      if (!s->stopped && s->state != "lost" && s->state != "error") {
        s->change_count += 1;
        s->last_activity_ms = WatchNowSteadyMs();
        s->state = "active";
      }
    }
    return S_OK;
  }

 private:
  ~UiaWatchStructHandler() = default;

  volatile LONG ref_count_;
  std::mutex mu_;
  std::shared_ptr<WatchSlot> slot_;
};

class UiaWatchPropHandler final
    : public IUIAutomationPropertyChangedEventHandler {
 public:
  explicit UiaWatchPropHandler(std::shared_ptr<WatchSlot> slot)
      : ref_count_(1), slot_(std::move(slot)) {}

  void Detach() {
    std::lock_guard<std::mutex> lk(mu_);
    slot_.reset();
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&ref_count_));
  }

  ULONG STDMETHODCALLTYPE Release() override {
    LONG next = InterlockedDecrement(&ref_count_);
    if (next <= 0) {
      delete this;
      return 0;
    }
    return static_cast<ULONG>(next);
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppvObject) override {
    if (ppvObject == nullptr) return E_POINTER;
    if (riid == __uuidof(IUnknown) ||
        riid == __uuidof(IUIAutomationPropertyChangedEventHandler)) {
      *ppvObject = static_cast<IUIAutomationPropertyChangedEventHandler*>(this);
      AddRef();
      return S_OK;
    }
    *ppvObject = nullptr;
    return E_NOINTERFACE;
  }

  HRESULT STDMETHODCALLTYPE HandlePropertyChangedEvent(
      IUIAutomationElement* /*sender*/, PROPERTYID /*propertyId*/,
      VARIANT /*newValue*/) override {
    std::shared_ptr<WatchSlot> s;
    {
      std::lock_guard<std::mutex> lk(mu_);
      s = slot_;
    }
    if (s) {
      std::lock_guard<std::mutex> slk(s->state_mu);
      if (!s->stopped && s->state != "lost" && s->state != "error") {
        s->change_count += 1;
        s->last_activity_ms = WatchNowSteadyMs();
        s->state = "active";
      }
    }
    return S_OK;
  }

 private:
  ~UiaWatchPropHandler() = default;

  volatile LONG ref_count_;
  std::mutex mu_;
  std::shared_ptr<WatchSlot> slot_;
};

inline void AppendU32Le(std::vector<uint8_t>* buf, uint32_t val) {
  buf->push_back(static_cast<uint8_t>(val & 0xFFu));
  buf->push_back(static_cast<uint8_t>((val >> 8) & 0xFFu));
  buf->push_back(static_cast<uint8_t>((val >> 16) & 0xFFu));
  buf->push_back(static_cast<uint8_t>((val >> 24) & 0xFFu));
}

inline bool ComputeUiaStructuralDigest(IUIAutomation* uia,
                                       IUIAutomationElement* root,
                                       std::vector<uint8_t>* out_digest32) {
  if (uia == nullptr || root == nullptr) return false;
  IUIAutomationTreeWalker* walker = nullptr;
  if (FAILED(uia->get_ControlViewWalker(&walker)) || walker == nullptr) {
    return false;
  }

  struct QueueItem {
    IUIAutomationElement* elem;
    uint32_t depth;
  };
  std::vector<QueueItem> queue;
  root->AddRef();
  queue.push_back({root, 0});

  std::vector<uint8_t> raw_bytes;
  raw_bytes.reserve(2048);

  constexpr uint32_t kMaxNodes = 256;
  constexpr uint32_t kMaxDepth = 12;
  uint32_t visited_nodes = 0;

  for (size_t i = 0; i < queue.size(); ++i) {
    IUIAutomationElement* el = queue[i].elem;
    uint32_t depth = queue[i].depth;
    if (visited_nodes < kMaxNodes) {
      ++visited_nodes;
      CONTROLTYPEID ctrl_type = 0;
      el->get_CurrentControlType(&ctrl_type);

      BOOL is_enabled = FALSE;
      el->get_CurrentIsEnabled(&is_enabled);
      BOOL is_offscreen = FALSE;
      el->get_CurrentIsOffscreen(&is_offscreen);
      BOOL is_pwd = FALSE;
      el->get_CurrentIsPassword(&is_pwd);

      uint32_t name_len = 0;
      BSTR name_bstr = nullptr;
      if (SUCCEEDED(el->get_CurrentName(&name_bstr)) && name_bstr != nullptr) {
        name_len = static_cast<uint32_t>(SysStringLen(name_bstr));
        SysFreeString(name_bstr);
      }

      uint32_t value_len = 0;
      if (!is_pwd) {
        IUIAutomationValuePattern* val_pat = nullptr;
        if (SUCCEEDED(el->GetCurrentPatternAs(
                UIA_ValuePatternId, __uuidof(IUIAutomationValuePattern),
                reinterpret_cast<void**>(&val_pat))) &&
            val_pat != nullptr) {
          BSTR bval = nullptr;
          if (SUCCEEDED(val_pat->get_CurrentValue(&bval)) && bval != nullptr) {
            value_len = static_cast<uint32_t>(SysStringLen(bval));
            SysFreeString(bval);
          }
          val_pat->Release();
        }
      }

      AppendU32Le(&raw_bytes, depth);
      AppendU32Le(&raw_bytes, static_cast<uint32_t>(ctrl_type));
      AppendU32Le(&raw_bytes, name_len);
      AppendU32Le(&raw_bytes, value_len);
      raw_bytes.push_back(is_enabled ? 1 : 0);
      raw_bytes.push_back(is_offscreen ? 1 : 0);

      if (depth < kMaxDepth &&
          queue.size() < static_cast<size_t>(kMaxNodes) * 2) {
        IUIAutomationElement* child = nullptr;
        if (SUCCEEDED(walker->GetFirstChildElement(el, &child)) &&
            child != nullptr) {
          uint32_t child_count = 0;
          for (; child != nullptr && child_count < 40u &&
                 queue.size() < static_cast<size_t>(kMaxNodes) * 2;
               ++child_count) {
            queue.push_back({child, depth + 1});
            IUIAutomationElement* next = nullptr;
            if (FAILED(walker->GetNextSiblingElement(child, &next))) {
              next = nullptr;
            }
            child = next;
          }
          if (child != nullptr) {
            child->Release();
          }
        }
      }
    }
    el->Release();
  }

  AppendU32Le(&raw_bytes, visited_nodes);
  walker->Release();
  return ComputeSha256(raw_bytes, out_digest32);
}

inline void RunUiWatchThread(std::shared_ptr<WatchSlot> slot, HWND hwnd,
                             DWORD target_pid) {
  HRESULT hr_com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  IUIAutomation* uia = nullptr;
  IUIAutomationElement* root = nullptr;

  if (FAILED(hr_com) ||
      FAILED(CoCreateInstance(__uuidof(CUIAutomation), nullptr,
                              CLSCTX_INPROC_SERVER, __uuidof(IUIAutomation),
                              reinterpret_cast<void**>(&uia))) ||
      uia == nullptr || FAILED(uia->ElementFromHandle(hwnd, &root)) ||
      root == nullptr) {
    if (root) root->Release();
    if (uia) uia->Release();
    if (SUCCEEDED(hr_com)) CoUninitialize();
    {
      std::lock_guard<std::mutex> lk(slot->state_mu);
      slot->init_ok = false;
      slot->init_error = {"failed", "target_not_found",
                          "Unable to attach UIA to target window"};
    }
    SetEvent(slot->ready_event);
    return;
  }

  HANDLE h_proc = OpenProcess(SYNCHRONIZE, FALSE, target_pid);

  auto* struct_handler = new UiaWatchStructHandler(slot);
  auto* prop_handler = new UiaWatchPropHandler(slot);
  bool struct_ok = SUCCEEDED(uia->AddStructureChangedEventHandler(
      root, TreeScope_Subtree, nullptr, struct_handler));
  PROPERTYID kPropIds[] = {
      UIA_NamePropertyId,
      UIA_ValueValuePropertyId,
      UIA_ToggleToggleStatePropertyId,
      UIA_ExpandCollapseExpandCollapseStatePropertyId,
      UIA_IsEnabledPropertyId,
      UIA_BoundingRectanglePropertyId,
  };
  bool prop_ok = SUCCEEDED(uia->AddPropertyChangedEventHandler(
      root, TreeScope_Subtree, nullptr, prop_handler, kPropIds,
      static_cast<int>(ARRAYSIZE(kPropIds))));

  std::vector<uint8_t> prev_digest;
  ComputeUiaStructuralDigest(uia, root, &prev_digest);

  {
    std::lock_guard<std::mutex> lk(slot->state_mu);
    slot->event_driven = (struct_ok || prop_ok);
    slot->fallback_used = !(struct_ok || prop_ok);
    slot->init_ok = true;
  }
  SetEvent(slot->ready_event);

  int64_t last_digest_ms = WatchNowSteadyMs();
  for (;;) {
    DWORD wait_res = WaitForSingleObject(slot->stop_event, 500);
    if (wait_res == WAIT_OBJECT_0) {
      break;
    }

    if (!IsWindow(hwnd) ||
        (h_proc != nullptr &&
         WaitForSingleObject(h_proc, 0) == WAIT_OBJECT_0)) {
      std::lock_guard<std::mutex> lk(slot->state_mu);
      if (!slot->stopped) {
        slot->state = "lost";
      }
      break;
    }

    int64_t now_ms = WatchNowSteadyMs();
    if (now_ms - last_digest_ms >= 2000) {
      last_digest_ms = now_ms;
      std::vector<uint8_t> next_digest;
      if (ComputeUiaStructuralDigest(uia, root, &next_digest)) {
        std::lock_guard<std::mutex> lk(slot->state_mu);
        if (!slot->stopped && slot->state != "lost" && slot->state != "error") {
          if (!prev_digest.empty() && prev_digest != next_digest) {
            prev_digest = std::move(next_digest);
            slot->digest_change_count += 1;
            slot->change_count += 1;
            slot->last_activity_ms = now_ms;
            slot->state = "active";
          } else {
            if (prev_digest.empty()) {
              prev_digest = std::move(next_digest);
            }
            if (now_ms - slot->last_activity_ms >= 2000) {
              slot->state = "idle";
            }
          }
        }
      }
    } else {
      std::lock_guard<std::mutex> lk(slot->state_mu);
      if (!slot->stopped && slot->state == "active" &&
          (now_ms - slot->last_activity_ms >= 2000)) {
        slot->state = "idle";
      }
    }
  }

  if (struct_ok) {
    uia->RemoveStructureChangedEventHandler(root, struct_handler);
  }
  if (prop_ok) {
    uia->RemovePropertyChangedEventHandler(root, prop_handler);
  }
  struct_handler->Detach();
  prop_handler->Detach();
  struct_handler->Release();
  prop_handler->Release();
  if (h_proc != nullptr) CloseHandle(h_proc);
  root->Release();
  uia->Release();
  CoUninitialize();
}

inline bool CollectProcessTreeCpuWin(
    DWORD root_pid,
    std::unordered_map<DWORD, std::pair<uint64_t, uint64_t>>* out_cpu_by_pid) {
  out_cpu_by_pid->clear();
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) return false;

  std::unordered_map<DWORD, std::vector<DWORD>> children_by_parent;
  PROCESSENTRY32W pe = {};
  pe.dwSize = sizeof(pe);
  if (Process32FirstW(snap, &pe)) {
    do {
      children_by_parent[pe.th32ParentProcessID].push_back(pe.th32ProcessID);
    } while (Process32NextW(snap, &pe));
  }
  CloseHandle(snap);

  std::vector<DWORD> queue;
  std::unordered_set<DWORD> visited;
  queue.push_back(root_pid);
  visited.insert(root_pid);

  for (size_t i = 0; i < queue.size() && visited.size() < size_t{256}; ++i) {
    DWORD cur = queue[i];
    auto it = children_by_parent.find(cur);
    if (it != children_by_parent.end()) {
      for (DWORD child : it->second) {
        if (child != 0 && visited.find(child) == visited.end()) {
          visited.insert(child);
          queue.push_back(child);
        }
      }
    }
  }

  for (DWORD p : queue) {
    HANDLE hp = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, p);
    if (hp == nullptr) continue;
    FILETIME ft_create = {}, ft_exit = {}, ft_kernel = {}, ft_user = {};
    if (GetProcessTimes(hp, &ft_create, &ft_exit, &ft_kernel, &ft_user)) {
      uint64_t cpu_100ns =
          FileTimeToUint64(ft_kernel) + FileTimeToUint64(ft_user);
      uint64_t create_100ns = FileTimeToUint64(ft_create);
      (*out_cpu_by_pid)[p] = {create_100ns, cpu_100ns};
    }
    CloseHandle(hp);
  }
  return true;
}

inline void RunProcessWatchThread(std::shared_ptr<WatchSlot> slot,
                                  DWORD root_pid) {
  HANDLE h_root = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                              FALSE, root_pid);
  if (h_root == nullptr || WaitForSingleObject(h_root, 0) != WAIT_TIMEOUT) {
    if (h_root != nullptr) CloseHandle(h_root);
    {
      std::lock_guard<std::mutex> lk(slot->state_mu);
      slot->init_ok = false;
      slot->init_error = {"failed", "target_not_found",
                          "Target process is not running"};
    }
    SetEvent(slot->ready_event);
    return;
  }

  std::unordered_map<DWORD, std::pair<uint64_t, uint64_t>> prev_samples;
  CollectProcessTreeCpuWin(root_pid, &prev_samples);
  int64_t prev_wall_ms = WatchNowSteadyMs();
  bool was_busy = false;

  {
    std::lock_guard<std::mutex> lk(slot->state_mu);
    slot->event_driven = false;
    slot->fallback_used = false;
    slot->init_ok = true;
  }
  SetEvent(slot->ready_event);

  for (;;) {
    DWORD wait_res = WaitForSingleObject(slot->stop_event, 1000);
    if (wait_res == WAIT_OBJECT_0) {
      break;
    }

    if (WaitForSingleObject(h_root, 0) == WAIT_OBJECT_0) {
      std::lock_guard<std::mutex> lk(slot->state_mu);
      if (!slot->stopped) {
        slot->state = "lost";
      }
      break;
    }

    int64_t now_ms = WatchNowSteadyMs();
    int64_t elapsed_ms = (now_ms > prev_wall_ms) ? (now_ms - prev_wall_ms) : 1000;
    double elapsed_100ns = static_cast<double>(elapsed_ms) * 10000.0;
    prev_wall_ms = now_ms;

    std::unordered_map<DWORD, std::pair<uint64_t, uint64_t>> cur_samples;
    CollectProcessTreeCpuWin(root_pid, &cur_samples);

    uint64_t total_delta_100ns = 0;
    bool has_busy_child = false;
    for (const auto& kv : cur_samples) {
      DWORD p = kv.first;
      uint64_t create_ts = kv.second.first;
      uint64_t cpu_ts = kv.second.second;

      uint64_t delta = 0;
      auto prev_it = prev_samples.find(p);
      bool is_new = (prev_it == prev_samples.end() ||
                     prev_it->second.first != create_ts);
      if (is_new) {
        delta = cpu_ts;
      } else if (cpu_ts >= prev_it->second.second) {
        delta = cpu_ts - prev_it->second.second;
      }
      total_delta_100ns += delta;

      if (p != root_pid) {
        double child_pct =
            (static_cast<double>(delta) * 100.0) / elapsed_100ns;
        if (child_pct > 3.0 || (is_new && cpu_ts > 0)) {
          has_busy_child = true;
        }
      }
    }

    double total_cpu_pct =
        (static_cast<double>(total_delta_100ns) * 100.0) / elapsed_100ns;
    std::string next_state =
        EvaluateProcessIdleStateWin(total_cpu_pct, has_busy_child, was_busy);
    was_busy = (next_state == "active");
    prev_samples = std::move(cur_samples);

    std::lock_guard<std::mutex> lk(slot->state_mu);
    if (!slot->stopped && slot->state != "lost" && slot->state != "error") {
      slot->state = next_state;
      if (was_busy) {
        slot->change_count += 1;
        slot->last_activity_ms = now_ms;
      }
    }
  }

  CloseHandle(h_root);
}

inline void RunFsWatchThread(std::shared_ptr<WatchSlot> slot,
                             std::wstring canonical_dir) {
  HANDLE h_dir = CreateFileW(
      canonical_dir.c_str(), FILE_LIST_DIRECTORY,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
      nullptr);
  if (h_dir == INVALID_HANDLE_VALUE) {
    std::lock_guard<std::mutex> lk(slot->state_mu);
    slot->init_ok = false;
    slot->init_error = {"failed", "workspace_not_found",
                        "Unable to open workspace directory for watching"};
    SetEvent(slot->ready_event);
    return;
  }

  HANDLE h_io_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (h_io_event == nullptr) {
    CloseHandle(h_dir);
    std::lock_guard<std::mutex> lk(slot->state_mu);
    slot->init_ok = false;
    slot->init_error = {"failed", "watch_unsupported",
                        "Unable to create overlapped I/O event"};
    SetEvent(slot->ready_event);
    return;
  }

  {
    std::lock_guard<std::mutex> lk(slot->state_mu);
    slot->event_driven = true;
    slot->fallback_used = false;
    slot->init_ok = true;
  }
  SetEvent(slot->ready_event);

  std::vector<DWORD> notify_words(16 * 1024);
  constexpr DWORD kNotifyFilter = FILE_NOTIFY_CHANGE_LAST_WRITE |
                                  FILE_NOTIFY_CHANGE_FILE_NAME |
                                  FILE_NOTIFY_CHANGE_SIZE;

  auto process_notify_buffer = [&](DWORD bytes) {
    uint64_t valid_events = 0;
    if (bytes == 0) {
      valid_events = 1;
    } else {
      const size_t max_buf_bytes = notify_words.size() * sizeof(DWORD);
      const size_t total_bytes =
          std::min(static_cast<size_t>(bytes), max_buf_bytes);
      const auto* raw =
          reinterpret_cast<const uint8_t*>(notify_words.data());
      constexpr size_t kHeaderSize =
          offsetof(FILE_NOTIFY_INFORMATION, FileName);
      size_t offset = 0;
      while (offset + kHeaderSize <= total_bytes) {
        const auto* fni =
            reinterpret_cast<const FILE_NOTIFY_INFORMATION*>(raw + offset);
        const size_t fname_offset = offset + kHeaderSize;
        const size_t fname_bytes = static_cast<size_t>(fni->FileNameLength);
        if (fname_bytes <= total_bytes - fname_offset &&
            (fname_bytes % sizeof(wchar_t)) == 0) {
          size_t wchar_count = fname_bytes / sizeof(wchar_t);
          std::wstring rel_name(fni->FileName, wchar_count);
          if (!IsExcludedRelativeFsPathWin(rel_name)) {
            ++valid_events;
          }
        } else {
          break;
        }
        if (fni->NextEntryOffset == 0) {
          break;
        }
        const size_t next_step = static_cast<size_t>(fni->NextEntryOffset);
        if (next_step > total_bytes - offset) {
          break;
        }
        offset += next_step;
      }
    }
    if (valid_events > 0) {
      std::lock_guard<std::mutex> lk(slot->state_mu);
      if (!slot->stopped && slot->state != "lost" && slot->state != "error") {
        slot->change_count += valid_events;
        slot->last_activity_ms = WatchNowSteadyMs();
        slot->state = "active";
      }
    }
  };

  bool keep_running = true;
  while (keep_running) {
    OVERLAPPED ov = {};
    ov.hEvent = h_io_event;
    ResetEvent(h_io_event);
    BOOL issued = ReadDirectoryChangesW(
        h_dir, notify_words.data(),
        static_cast<DWORD>(notify_words.size() * sizeof(DWORD)), TRUE,
        kNotifyFilter, nullptr, &ov, nullptr);
    if (!issued && GetLastError() != ERROR_IO_PENDING) {
      std::lock_guard<std::mutex> lk(slot->state_mu);
      if (!slot->stopped) {
        slot->state = "lost";
      }
      break;
    }

    for (;;) {
      HANDLE waits[2] = {slot->stop_event, h_io_event};
      DWORD wait_res = WaitForMultipleObjects(2, waits, FALSE, 1500);
      if (wait_res == WAIT_OBJECT_0) {
        CancelIoEx(h_dir, &ov);
        DWORD drained = 0;
        if (GetOverlappedResult(h_dir, &ov, &drained, TRUE) && drained > 0) {
          process_notify_buffer(drained);
        }
        keep_running = false;
        break;
      }

      if (wait_res == WAIT_TIMEOUT) {
        DWORD attrs = GetFileAttributesW(canonical_dir.c_str());
        if (attrs == INVALID_FILE_ATTRIBUTES ||
            (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0) {
          CancelIoEx(h_dir, &ov);
          DWORD drained = 0;
          GetOverlappedResult(h_dir, &ov, &drained, TRUE);
          std::lock_guard<std::mutex> lk(slot->state_mu);
          if (!slot->stopped) {
            slot->state = "lost";
          }
          keep_running = false;
          break;
        }
        int64_t now_ms = WatchNowSteadyMs();
        std::lock_guard<std::mutex> lk(slot->state_mu);
        if (!slot->stopped && slot->state == "active" &&
            (now_ms - slot->last_activity_ms >= 1500)) {
          slot->state = "idle";
        }
        continue;
      }

      if (wait_res == WAIT_OBJECT_0 + 1) {
        DWORD bytes = 0;
        if (!GetOverlappedResult(h_dir, &ov, &bytes, FALSE)) {
          std::lock_guard<std::mutex> lk(slot->state_mu);
          if (!slot->stopped) {
            slot->state = "lost";
          }
          keep_running = false;
          break;
        }
        process_notify_buffer(bytes);
        break;
      }

      CancelIoEx(h_dir, &ov);
      DWORD drained = 0;
      GetOverlappedResult(h_dir, &ov, &drained, TRUE);
      keep_running = false;
      break;
    }
  }

  CloseHandle(h_io_event);
  CloseHandle(h_dir);
}

class WatchManager {
 public:
  static constexpr size_t kMaxSlots = 12;

  static WatchManager& Instance() {
    static auto* inst = new WatchManager();
    return *inst;
  }

  bool WatchStart(const flutter::EncodableMap& args,
                  flutter::EncodableMap* out_map, WatchError* out_err) {
    std::string raw_watch_id;
    std::string signal;
    if (!ExtractStringArgWatch(args, "watchId", &raw_watch_id) ||
        !ExtractStringArgWatch(args, "signal", &signal)) {
      *out_err = {"invalid_args", "invalid_args",
                  "Missing watchId or signal"};
      return false;
    }
    std::string watch_id = TrimAsciiWatch(raw_watch_id);
    if (watch_id.empty() ||
        (signal != "ui_quiescence" && signal != "ui_change" &&
         signal != "process_idle" && signal != "fs_quiescence")) {
      *out_err = {"invalid_args", "invalid_args",
                  "Invalid watchId or unsupported signal"};
      return false;
    }

    std::string key = watch_id + ":" + signal;
    std::shared_ptr<WatchSlot> old_slot;
    {
      std::lock_guard<std::mutex> lk(mu_);
      auto it = slots_.find(key);
      if (it != slots_.end()) {
        old_slot = it->second;
        slots_.erase(it);
      }
      if (slots_.size() >= kMaxSlots) {
        *out_err = {"failed", "watch_limit_reached",
                    "Maximum concurrent native watches reached"};
        return false;
      }
    }
    if (old_slot) {
      StopAndJoinSlot(old_slot);
    }

    auto slot = std::make_shared<WatchSlot>();
    slot->watch_id = watch_id;
    slot->signal = signal;
    slot->key = key;
    slot->stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    slot->ready_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (slot->stop_event == nullptr || slot->ready_event == nullptr) {
      StopAndJoinSlot(slot);
      *out_err = {"failed", "watch_unsupported",
                  "Unable to allocate watch synchronization events"};
      return false;
    }

    if (signal == "ui_quiescence" || signal == "ui_change") {
      HWND hwnd = nullptr;
      DWORD target_pid = 0;
      if (!ResolveUiWatchTargetWin(args, &hwnd, &target_pid, out_err)) {
        StopAndJoinSlot(slot);
        return false;
      }
      slot->worker = std::thread(RunUiWatchThread, slot, hwnd, target_pid);
    } else if (signal == "process_idle") {
      int64_t raw_pid = 0;
      if (!ExtractIntArgWatch(args, "pid", &raw_pid) || raw_pid <= 0 ||
          raw_pid > 0x7FFFFFFFLL) {
        StopAndJoinSlot(slot);
        *out_err = {"failed", "target_not_found",
                    "process_idle requires positive pid"};
        return false;
      }
      DWORD target_pid = static_cast<DWORD>(raw_pid);
      HANDLE hp = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                              target_pid);
      if (hp == nullptr) {
        StopAndJoinSlot(slot);
        *out_err = {"failed", "target_not_found",
                    "Target pid does not exist"};
        return false;
      }
      wchar_t img_path[MAX_PATH] = {};
      DWORD img_len = MAX_PATH;
      std::string proc_stem;
      if (QueryFullProcessImageNameW(hp, 0, img_path, &img_len)) {
        std::wstring full(img_path, img_len);
        size_t slash = full.find_last_of(L"\\/");
        std::wstring base =
            slash != std::wstring::npos ? full.substr(slash + 1) : full;
        proc_stem = WideToUtf8(base);
      }
      CloseHandle(hp);
      if (!proc_stem.empty() && IsHardDeniedWindowsAppStem(proc_stem)) {
        StopAndJoinSlot(slot);
        *out_err = {"denied", "policy_blocked",
                    "Target process is blocked by policy"};
        return false;
      }
      slot->worker = std::thread(RunProcessWatchThread, slot, target_pid);
    } else if (signal == "fs_quiescence") {
      std::string raw_path;
      if (!ExtractStringArgWatch(args, "workspacePath", &raw_path)) {
        StopAndJoinSlot(slot);
        *out_err = {"invalid_args", "workspace_not_found",
                    "fs_quiescence requires workspacePath"};
        return false;
      }
      std::wstring canonical_dir;
      if (!ValidateWatchWorkspacePathWin(raw_path, &canonical_dir, out_err)) {
        StopAndJoinSlot(slot);
        return false;
      }
      slot->worker = std::thread(RunFsWatchThread, slot, canonical_dir);
    }

    WaitForSingleObject(slot->ready_event, 3000);
    bool init_ok = false;
    bool event_driven = false;
    bool fallback_used = false;
    {
      std::lock_guard<std::mutex> lk(slot->state_mu);
      init_ok = slot->init_ok;
      event_driven = slot->event_driven;
      fallback_used = slot->fallback_used;
      if (!init_ok) {
        *out_err = slot->init_error;
      }
    }

    if (!init_ok) {
      StopAndJoinSlot(slot);
      if (out_err->error_code.empty()) {
        *out_err = {"failed", "watch_unsupported",
                    "Watch initialization timed out or failed"};
      }
      return false;
    }

    std::shared_ptr<WatchSlot> displaced_slot;
    bool limit_exceeded = false;
    {
      std::lock_guard<std::mutex> lk(mu_);
      auto it = slots_.find(key);
      if (it == slots_.end()) {
        if (slots_.size() >= kMaxSlots) {
          limit_exceeded = true;
        } else {
          slots_[key] = slot;
        }
      } else {
        displaced_slot = it->second;
        it->second = slot;
      }
    }
    if (limit_exceeded) {
      *out_err = {"failed", "watch_limit_reached",
                  "Maximum concurrent native watches reached"};
      StopAndJoinSlot(slot);
      return false;
    }
    if (displaced_slot) {
      StopAndJoinSlot(displaced_slot);
    }

    (*out_map)[flutter::EncodableValue("accepted")] =
        flutter::EncodableValue(true);
    (*out_map)[flutter::EncodableValue("watchId")] =
        flutter::EncodableValue(watch_id);
    (*out_map)[flutter::EncodableValue("signal")] =
        flutter::EncodableValue(signal);
    (*out_map)[flutter::EncodableValue("eventDriven")] =
        flutter::EncodableValue(event_driven);
    (*out_map)[flutter::EncodableValue("fallbackUsed")] =
        flutter::EncodableValue(fallback_used);
    return true;
  }

  bool WatchPoll(const flutter::EncodableMap& args,
                 flutter::EncodableMap* out_map, WatchError* out_err) {
    std::string raw_watch_id;
    std::string signal;
    if (!ExtractStringArgWatch(args, "watchId", &raw_watch_id) ||
        !ExtractStringArgWatch(args, "signal", &signal)) {
      *out_err = {"invalid_args", "invalid_args",
                  "Missing watchId or signal"};
      return false;
    }
    std::string watch_id = TrimAsciiWatch(raw_watch_id);
    if (watch_id.empty() || signal.empty()) {
      *out_err = {"invalid_args", "invalid_args",
                  "Empty watchId or signal"};
      return false;
    }

    std::string key = watch_id + ":" + signal;
    std::shared_ptr<WatchSlot> slot;
    {
      std::lock_guard<std::mutex> lk(mu_);
      auto it = slots_.find(key);
      if (it != slots_.end()) {
        slot = it->second;
      }
    }

    if (!slot) {
      (*out_map)[flutter::EncodableValue("watchId")] =
          flutter::EncodableValue(watch_id);
      (*out_map)[flutter::EncodableValue("signal")] =
          flutter::EncodableValue(signal);
      (*out_map)[flutter::EncodableValue("state")] =
          flutter::EncodableValue("lost");
      (*out_map)[flutter::EncodableValue("changeCount")] =
          flutter::EncodableValue(static_cast<int64_t>(0));
      (*out_map)[flutter::EncodableValue("digestChangeCount")] =
          flutter::EncodableValue(static_cast<int64_t>(0));
      (*out_map)[flutter::EncodableValue("digestChanged")] =
          flutter::EncodableValue(false);
      (*out_map)[flutter::EncodableValue("eventDriven")] =
          flutter::EncodableValue(false);
      (*out_map)[flutter::EncodableValue("fallbackUsed")] =
          flutter::EncodableValue(false);
      return true;
    }

    std::lock_guard<std::mutex> lk(slot->state_mu);
    bool digest_changed =
        slot->digest_change_count > slot->last_polled_digest_change_count;
    slot->last_polled_digest_change_count = slot->digest_change_count;

    (*out_map)[flutter::EncodableValue("watchId")] =
        flutter::EncodableValue(watch_id);
    (*out_map)[flutter::EncodableValue("signal")] =
        flutter::EncodableValue(signal);
    (*out_map)[flutter::EncodableValue("state")] =
        flutter::EncodableValue(slot->state);
    (*out_map)[flutter::EncodableValue("changeCount")] =
        flutter::EncodableValue(static_cast<int64_t>(slot->change_count));
    (*out_map)[flutter::EncodableValue("digestChangeCount")] =
        flutter::EncodableValue(
            static_cast<int64_t>(slot->digest_change_count));
    (*out_map)[flutter::EncodableValue("digestChanged")] =
        flutter::EncodableValue(digest_changed);
    (*out_map)[flutter::EncodableValue("eventDriven")] =
        flutter::EncodableValue(slot->event_driven);
    (*out_map)[flutter::EncodableValue("fallbackUsed")] =
        flutter::EncodableValue(slot->fallback_used);
    if (!slot->error_code.empty()) {
      (*out_map)[flutter::EncodableValue("errorCode")] =
          flutter::EncodableValue(slot->error_code);
    }
    return true;
  }

  bool WatchStop(const flutter::EncodableMap& args,
                 flutter::EncodableMap* out_map, WatchError* out_err) {
    std::string raw_watch_id;
    if (!ExtractStringArgWatch(args, "watchId", &raw_watch_id)) {
      *out_err = {"invalid_args", "invalid_args", "Missing watchId"};
      return false;
    }
    std::string watch_id = TrimAsciiWatch(raw_watch_id);
    if (watch_id.empty()) {
      *out_err = {"invalid_args", "invalid_args", "Empty watchId"};
      return false;
    }
    std::string signal;
    ExtractStringArgWatch(args, "signal", &signal);
    signal = TrimAsciiWatch(signal);

    std::vector<std::shared_ptr<WatchSlot>> to_stop;
    {
      std::lock_guard<std::mutex> lk(mu_);
      if (!signal.empty()) {
        std::string key = watch_id + ":" + signal;
        auto it = slots_.find(key);
        if (it != slots_.end()) {
          to_stop.push_back(it->second);
          slots_.erase(it);
        }
      } else {
        std::string prefix = watch_id + ":";
        for (auto it = slots_.begin(); it != slots_.end();) {
          if (it->first.rfind(prefix, 0) == 0) {
            to_stop.push_back(it->second);
            it = slots_.erase(it);
          } else {
            ++it;
          }
        }
      }
    }

    for (const auto& slot : to_stop) {
      StopAndJoinSlot(slot);
    }

    (*out_map)[flutter::EncodableValue("stopped")] =
        flutter::EncodableValue(true);
    (*out_map)[flutter::EncodableValue("cancelledCount")] =
        flutter::EncodableValue(static_cast<int64_t>(to_stop.size()));
    return true;
  }

 private:
  WatchManager() = default;

  static void StopAndJoinSlot(const std::shared_ptr<WatchSlot>& slot) {
    if (!slot) return;
    {
      std::lock_guard<std::mutex> lk(slot->state_mu);
      slot->stopped = true;
    }
    if (slot->stop_event != nullptr) {
      SetEvent(slot->stop_event);
    }
    if (slot->worker.joinable()) {
      slot->worker.join();
    }
    if (slot->stop_event != nullptr) {
      CloseHandle(slot->stop_event);
      slot->stop_event = nullptr;
    }
    if (slot->ready_event != nullptr) {
      CloseHandle(slot->ready_event);
      slot->ready_event = nullptr;
    }
  }

  std::mutex mu_;
  std::unordered_map<std::string, std::shared_ptr<WatchSlot>> slots_;
};

}  // namespace xuna_win

#endif  // RUNNER_XUNA_WIN_WATCH_H_
