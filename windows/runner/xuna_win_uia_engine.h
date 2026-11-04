#ifndef RUNNER_XUNA_WIN_UIA_ENGINE_H_
#define RUNNER_XUNA_WIN_UIA_ENGINE_H_

#include "xuna_win_apps_browser.h"

namespace xuna_win {

struct WindowSearchContext {
  std::string query_lower;
  std::string query_compact;
  std::vector<std::string> query_tokens;
  HWND best_hwnd = nullptr;
  int best_score = 0;
};

inline std::string QueryProcessBaseNameForHwnd(HWND hwnd) {
  if (hwnd == nullptr) return std::string();
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0) return std::string();
  HANDLE h_proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (h_proc == nullptr) return std::string();
  wchar_t img_path[MAX_PATH] = {};
  DWORD img_len = MAX_PATH;
  std::string proc_stem;
  if (QueryFullProcessImageNameW(h_proc, 0, img_path, &img_len)) {
    std::wstring full(img_path, img_len);
    size_t slash = full.find_last_of(L"\\/");
    std::wstring base =
        slash != std::wstring::npos ? full.substr(slash + 1) : full;
    proc_stem = WideToUtf8(base);
    if (proc_stem.size() > 4 &&
        ToLowerAscii(proc_stem.substr(proc_stem.size() - 4)) == ".exe") {
      proc_stem = proc_stem.substr(0, proc_stem.size() - 4);
    }
  }
  CloseHandle(h_proc);
  return proc_stem;
}

inline bool IsHardDeniedOrElevatedHwnd(HWND hwnd) {
  if (hwnd == nullptr) return false;
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid != 0) {
    HANDLE h_proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (h_proc != nullptr) {
      HANDLE h_tok = nullptr;
      bool elevated = false;
      if (OpenProcessToken(h_proc, TOKEN_QUERY, &h_tok) && h_tok != nullptr) {
        TOKEN_ELEVATION elev = {};
        DWORD ret_len = 0;
        if (GetTokenInformation(h_tok, TokenElevation, &elev, sizeof(elev),
                                &ret_len)) {
          elevated = (elev.TokenIsElevated != 0);
        }
        CloseHandle(h_tok);
      }
      CloseHandle(h_proc);
      if (elevated) return true;
    }
  }
  wchar_t title_buf[512] = {};
  GetWindowTextW(hwnd, title_buf, 512);
  std::string combined = ToLowerAscii(
      WideToUtf8(std::wstring(title_buf)) + " " + QueryProcessBaseNameForHwnd(hwnd));
  static const char* kDeniedTokens[] = {
      "1password",  "bitwarden", "keepass",  "lastpass", "dashlane",
      "credential", "regedit",   "taskmgr",  "mmc",      "consent"};
  for (const char* token : kDeniedTokens) {
    if (combined.find(token) != std::string::npos) {
      return true;
    }
  }
  return false;
}

inline BOOL CALLBACK EnumWindowsMatchCallback(HWND hwnd, LPARAM lparam) {
  if (!IsWindowVisible(hwnd)) return TRUE;
  wchar_t title_buf[512] = {};
  GetWindowTextW(hwnd, title_buf, 512);
  std::string title = WideToUtf8(std::wstring(title_buf));
  std::string proc_stem = QueryProcessBaseNameForHwnd(hwnd);
  if (title.empty() && proc_stem.empty()) return TRUE;

  auto* ctx = reinterpret_cast<WindowSearchContext*>(lparam);
  int s1 = ScoreCandidateName(title, ctx->query_lower, ctx->query_compact,
                              ctx->query_tokens);
  int s2 = ScoreCandidateName(proc_stem, ctx->query_lower, ctx->query_compact,
                              ctx->query_tokens);
  int score = std::max(s1, s2);
  if (score > ctx->best_score) {
    ctx->best_score = score;
    ctx->best_hwnd = hwnd;
  }
  return TRUE;
}

inline HWND FindMatchingTopLevelWindow(const std::string& query) {
  WindowSearchContext ctx;
  ctx.query_lower = ToLowerAscii(query);
  ctx.query_compact = CompactAlphaNumLower(query);
  ctx.query_tokens = SplitAlphaNumTokens(query);
  if (ctx.query_compact.empty()) return nullptr;
  EnumWindows(EnumWindowsMatchCallback, reinterpret_cast<LPARAM>(&ctx));
  return ctx.best_score >= 25 ? ctx.best_hwnd : nullptr;
}

inline void ActivateWindowHandle(HWND hwnd) {
  if (hwnd == nullptr) return;
  if (IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  }
  HWND fg = GetForegroundWindow();
  DWORD fg_tid = fg ? GetWindowThreadProcessId(fg, nullptr) : 0;
  DWORD target_tid = GetWindowThreadProcessId(hwnd, nullptr);
  if (fg_tid != 0 && target_tid != 0 && fg_tid != target_tid) {
    AttachThreadInput(fg_tid, target_tid, TRUE);
    SetForegroundWindow(hwnd);
    BringWindowToTop(hwnd);
    AttachThreadInput(fg_tid, target_tid, FALSE);
  } else {
    SetForegroundWindow(hwnd);
    BringWindowToTop(hwnd);
  }
  Sleep(150);
}

inline HWND ResolveTargetWindow(const std::string& window_title_query,
                                bool activate) {
  std::string trimmed = window_title_query;
  while (!trimmed.empty() &&
         std::isspace(static_cast<unsigned char>(trimmed.front()))) {
    trimmed.erase(trimmed.begin());
  }
  while (!trimmed.empty() &&
         std::isspace(static_cast<unsigned char>(trimmed.back()))) {
    trimmed.pop_back();
  }
  std::string lower = ToLowerAscii(trimmed);
  if (trimmed.empty() || lower == "active" || lower == "frontmost") {
    return GetForegroundWindow();
  }

  HWND found = FindMatchingTopLevelWindow(trimmed);
  if (found == nullptr && activate) {
    LaunchAppOrWorkflow("exe", trimmed);
    for (int i = 0; i < 16; ++i) {
      Sleep(150);
      found = FindMatchingTopLevelWindow(trimmed);
      if (found != nullptr) break;
    }
  }
  if (found != nullptr && activate) {
    ActivateWindowHandle(found);
  }
  return found != nullptr ? found : GetForegroundWindow();
}

struct InteractiveUiaNode {
  IUIAutomationElement* element = nullptr;
  std::string ref_id;
  std::string role;
  std::string label;
  bool is_password = false;
  int center_x = -1;
  int center_y = -1;
};

inline bool InspectInteractiveUiaElement(IUIAutomationElement* el,
                                         std::string* out_role,
                                         std::string* out_label,
                                         bool* out_is_pwd,
                                         int* out_cx,
                                         int* out_cy) {
  if (el == nullptr) return false;
  BOOL is_enabled = TRUE;
  el->get_CurrentIsEnabled(&is_enabled);
  if (!is_enabled) return false;

  CONTROLTYPEID ctrl_type = 0;
  el->get_CurrentControlType(&ctrl_type);
  BOOL is_offscreen = FALSE;
  el->get_CurrentIsOffscreen(&is_offscreen);
  if (is_offscreen && ctrl_type != UIA_MenuItemControlTypeId) {
    return false;
  }

  bool is_interactive_type =
      ctrl_type == UIA_ButtonControlTypeId ||
      ctrl_type == UIA_EditControlTypeId ||
      ctrl_type == UIA_ComboBoxControlTypeId ||
      ctrl_type == UIA_CheckBoxControlTypeId ||
      ctrl_type == UIA_RadioButtonControlTypeId ||
      ctrl_type == UIA_HyperlinkControlTypeId ||
      ctrl_type == UIA_ListItemControlTypeId ||
      ctrl_type == UIA_MenuItemControlTypeId ||
      ctrl_type == UIA_TabItemControlTypeId ||
      ctrl_type == UIA_TreeItemControlTypeId ||
      ctrl_type == UIA_DataItemControlTypeId ||
      ctrl_type == UIA_SliderControlTypeId ||
      ctrl_type == UIA_DocumentControlTypeId ||
      ctrl_type == UIA_SplitButtonControlTypeId;
  bool is_editable_type =
      ctrl_type == UIA_EditControlTypeId ||
      ctrl_type == UIA_ComboBoxControlTypeId ||
      ctrl_type == UIA_DocumentControlTypeId;

  if (!is_interactive_type) {
    IUnknown* pat = nullptr;
    if (SUCCEEDED(el->GetCurrentPattern(UIA_InvokePatternId, &pat)) &&
        pat != nullptr) {
      is_interactive_type = true;
      pat->Release();
    } else if (SUCCEEDED(el->GetCurrentPattern(UIA_ValuePatternId, &pat)) &&
               pat != nullptr) {
      is_interactive_type = true;
      is_editable_type = true;
      pat->Release();
    }
  }
  if (!is_interactive_type) return false;

  BOOL is_pwd = FALSE;
  el->get_CurrentIsPassword(&is_pwd);
  *out_is_pwd = (is_pwd != FALSE);

  std::string role = "control";
  switch (ctrl_type) {
    case UIA_ButtonControlTypeId:
    case UIA_SplitButtonControlTypeId:
      role = "AXButton";
      break;
    case UIA_EditControlTypeId:
      role = "AXTextField";
      break;
    case UIA_ComboBoxControlTypeId:
      role = "AXComboBox";
      break;
    case UIA_DocumentControlTypeId:
      role = "AXTextArea";
      break;
    case UIA_MenuItemControlTypeId:
      role = "AXMenuItem";
      break;
    case UIA_ListItemControlTypeId:
    case UIA_DataItemControlTypeId:
    case UIA_TreeItemControlTypeId:
      role = "AXRow";
      break;
    case UIA_TabItemControlTypeId:
      role = "AXRadioButton";
      break;
    case UIA_HyperlinkControlTypeId:
      role = "AXLink";
      break;
    case UIA_CheckBoxControlTypeId:
      role = "AXCheckBox";
      break;
    default: {
      BSTR role_bstr = nullptr;
      if (SUCCEEDED(el->get_CurrentLocalizedControlType(&role_bstr)) &&
          role_bstr != nullptr) {
        role = TruncateUtf8(
            WideToUtf8(std::wstring(role_bstr, SysStringLen(role_bstr))), 32);
        SysFreeString(role_bstr);
      }
      break;
    }
  }
  *out_role = role;

  std::string label;
  BSTR name_bstr = nullptr;
  if (SUCCEEDED(el->get_CurrentName(&name_bstr)) && name_bstr != nullptr) {
    label = WideToUtf8(std::wstring(name_bstr, SysStringLen(name_bstr)));
    SysFreeString(name_bstr);
  }
  if (label.empty()) {
    BSTR help_bstr = nullptr;
    if (SUCCEEDED(el->get_CurrentHelpText(&help_bstr)) &&
        help_bstr != nullptr) {
      label = WideToUtf8(std::wstring(help_bstr, SysStringLen(help_bstr)));
      SysFreeString(help_bstr);
    }
  }
  if (label.empty()) {
    BSTR auto_id_bstr = nullptr;
    if (SUCCEEDED(el->get_CurrentAutomationId(&auto_id_bstr)) &&
        auto_id_bstr != nullptr) {
      label =
          WideToUtf8(std::wstring(auto_id_bstr, SysStringLen(auto_id_bstr)));
      SysFreeString(auto_id_bstr);
    }
  }
  if (label.empty() && is_editable_type) {
    label = "Search / Text Input";
  }
  if (label.empty()) return false;

  BSTR accel_bstr = nullptr;
  if (SUCCEEDED(el->get_CurrentAcceleratorKey(&accel_bstr)) &&
      accel_bstr != nullptr) {
    std::string accel =
        WideToUtf8(std::wstring(accel_bstr, SysStringLen(accel_bstr)));
    SysFreeString(accel_bstr);
    if (!accel.empty()) {
      label += " [" + accel + "]";
    }
  }

  if (*out_is_pwd) {
    label = "[REDACTED_PASSWORD_CONTROL]";
  } else {
    label = TruncateUtf8(label, 80);
  }
  *out_label = label;

  RECT rc = {};
  if (SUCCEEDED(el->get_CurrentBoundingRectangle(&rc)) &&
      rc.right > rc.left && rc.bottom > rc.top) {
    *out_cx = (rc.left + rc.right) / 2;
    *out_cy = (rc.top + rc.bottom) / 2;
  } else {
    *out_cx = -1;
    *out_cy = -1;
  }
  return true;
}

inline void CollectInteractiveUiaNodes(IUIAutomation* uia, HWND hwnd,
                                       int max_nodes, bool retain_elements,
                                       std::vector<InteractiveUiaNode>* out_items,
                                       int* out_redacted) {
  *out_redacted = 0;
  if (uia == nullptr || hwnd == nullptr) return;
  IUIAutomationElement* root = nullptr;
  if (FAILED(uia->ElementFromHandle(hwnd, &root)) || root == nullptr) return;
  IUIAutomationCondition* true_cond = nullptr;
  if (SUCCEEDED(uia->CreateTrueCondition(&true_cond)) && true_cond != nullptr) {
    IUIAutomationElementArray* arr = nullptr;
    if (SUCCEEDED(root->FindAll(TreeScope_Descendants, true_cond, &arr)) &&
        arr != nullptr) {
      int len = 0;
      arr->get_Length(&len);
      for (int i = 0;
           i < len && static_cast<int>(out_items->size()) < max_nodes; ++i) {
        IUIAutomationElement* el = nullptr;
        if (SUCCEEDED(arr->GetElement(i, &el)) && el != nullptr) {
          std::string role;
          std::string label;
          bool is_pwd = false;
          int cx = -1;
          int cy = -1;
          if (InspectInteractiveUiaElement(el, &role, &label, &is_pwd, &cx,
                                           &cy)) {
            if (is_pwd) ++(*out_redacted);
            InteractiveUiaNode item;
            item.ref_id = "ui_" + std::to_string(out_items->size() + 1);
            item.role = role;
            item.label = label;
            item.is_password = is_pwd;
            item.center_x = is_pwd ? -1 : cx;
            item.center_y = is_pwd ? -1 : cy;
            if (retain_elements && !is_pwd) {
              item.element = el;
            } else {
              el->Release();
            }
            out_items->push_back(item);
          } else {
            el->Release();
          }
        }
      }
      arr->Release();
    }
    true_cond->Release();
  }
  root->Release();
}

inline void ScanWindowUiTreeToEncodable(HWND hwnd, int max_nodes,
                                        flutter::EncodableList* out_nodes,
                                        int* out_redacted,
                                        std::string* out_win_title,
                                        std::string* out_app_name) {
  wchar_t title_buf[512] = {};
  if (hwnd != nullptr) {
    GetWindowTextW(hwnd, title_buf, 512);
  }
  *out_app_name = QueryProcessBaseNameForHwnd(hwnd);
  *out_win_title = TruncateUtf8(WideToUtf8(std::wstring(title_buf)), 120);
  if (out_win_title->empty()) {
    *out_win_title = out_app_name->empty() ? "Active Window" : *out_app_name;
  }
  if (IsHardDeniedOrElevatedHwnd(hwnd)) {
    return;
  }

  std::vector<InteractiveUiaNode> items;
  IUIAutomation* uia = nullptr;
  if (hwnd != nullptr &&
      SUCCEEDED(CoCreateInstance(__uuidof(CUIAutomation), nullptr,
                                 CLSCTX_INPROC_SERVER,
                                 __uuidof(IUIAutomation),
                                 reinterpret_cast<void**>(&uia))) &&
      uia != nullptr) {
    CollectInteractiveUiaNodes(uia, hwnd, max_nodes, false, &items,
                               out_redacted);
    uia->Release();
  }
  for (const auto& item : items) {
    flutter::EncodableMap node;
    node[flutter::EncodableValue("refId")] =
        flutter::EncodableValue(item.ref_id);
    node[flutter::EncodableValue("role")] = flutter::EncodableValue(item.role);
    node[flutter::EncodableValue("label")] =
        flutter::EncodableValue(item.label);
    node[flutter::EncodableValue("isPassword")] =
        flutter::EncodableValue(item.is_password);
    out_nodes->push_back(flutter::EncodableValue(node));
  }
}

inline void PostMouseClickScreenPoint(int x, int y, const std::string& button,
                                      int click_count) {
  if (x >= 0 && y >= 0) {
    SetCursorPos(x, y);
    Sleep(20);
  }
  DWORD down_flag = MOUSEEVENTF_LEFTDOWN;
  DWORD up_flag = MOUSEEVENTF_LEFTUP;
  if (button == "right") {
    down_flag = MOUSEEVENTF_RIGHTDOWN;
    up_flag = MOUSEEVENTF_RIGHTUP;
  } else if (button == "middle") {
    down_flag = MOUSEEVENTF_MIDDLEDOWN;
    up_flag = MOUSEEVENTF_MIDDLEUP;
  }
  int count = click_count < 1 ? 1 : (click_count > 3 ? 3 : click_count);
  for (int i = 0; i < count; ++i) {
    INPUT inputs[2] = {};
    inputs[0].type = INPUT_MOUSE;
    inputs[0].mi.dwFlags = down_flag;
    inputs[1].type = INPUT_MOUSE;
    inputs[1].mi.dwFlags = up_flag;
    SendInput(2, inputs, sizeof(INPUT));
    if (i + 1 < count) {
      Sleep(35);
    }
  }
}

inline void ClickScreenPoint(int x, int y) {
  PostMouseClickScreenPoint(x, y, "left", 1);
}

inline void PostMouseDragScreenPoints(int x1, int y1, int x2, int y2,
                                      int steps = 24) {
  SetCursorPos(x1, y1);
  Sleep(20);
  INPUT down = {};
  down.type = INPUT_MOUSE;
  down.mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
  SendInput(1, &down, sizeof(INPUT));
  int total = steps < 4 ? 4 : (steps > 48 ? 48 : steps);
  for (int i = 1; i <= total; ++i) {
    int cx = x1 + ((x2 - x1) * i) / total;
    int cy = y1 + ((y2 - y1) * i) / total;
    SetCursorPos(cx, cy);
    Sleep(12);
  }
  INPUT up = {};
  up.type = INPUT_MOUSE;
  up.mi.dwFlags = MOUSEEVENTF_LEFTUP;
  SendInput(1, &up, sizeof(INPUT));
}

inline void PostMouseScrollWheel(const std::string& direction, int ticks, int x,
                                 int y) {
  if (x >= 0 && y >= 0) {
    SetCursorPos(x, y);
    Sleep(15);
  }
  std::string dir = ToLowerAscii(direction);
  int clamped = ticks < 1 ? 1 : (ticks > 20 ? 20 : ticks);
  INPUT in = {};
  in.type = INPUT_MOUSE;
  if (dir == "left" || dir == "scroll_left" || dir == "right" ||
      dir == "scroll_right") {
    in.mi.dwFlags = MOUSEEVENTF_HWHEEL;
    in.mi.mouseData = static_cast<DWORD>(
        (dir.find("right") != std::string::npos ? 1 : -1) * WHEEL_DELTA *
        clamped);
  } else {
    in.mi.dwFlags = MOUSEEVENTF_WHEEL;
    in.mi.mouseData = static_cast<DWORD>(
        (dir.find("up") != std::string::npos ? 1 : -1) * WHEEL_DELTA * clamped);
  }
  SendInput(1, &in, sizeof(INPUT));
}

inline void SendKeyChord(WORD mod1, WORD mod2, WORD vk) {
  std::vector<INPUT> inputs;
  auto push_key = [&](WORD k, DWORD flags) {
    INPUT in = {};
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = k;
    in.ki.dwFlags = flags;
    inputs.push_back(in);
  };
  if (mod1 != 0) push_key(mod1, 0);
  if (mod2 != 0) push_key(mod2, 0);
  push_key(vk, 0);
  push_key(vk, KEYEVENTF_KEYUP);
  if (mod2 != 0) push_key(mod2, KEYEVENTF_KEYUP);
  if (mod1 != 0) push_key(mod1, KEYEVENTF_KEYUP);
  SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
}

inline void SendUnicodeTextInput(const std::string& utf8_text) {
  std::wstring wtext = Utf8ToWide(utf8_text);
  if (wtext.empty()) return;
  std::vector<INPUT> inputs;
  inputs.reserve(wtext.size() * 2);
  for (wchar_t ch : wtext) {
    INPUT down = {};
    down.type = INPUT_KEYBOARD;
    down.ki.wScan = static_cast<WORD>(ch);
    down.ki.dwFlags = KEYEVENTF_UNICODE;
    inputs.push_back(down);
    INPUT up = {};
    up.type = INPUT_KEYBOARD;
    up.ki.wScan = static_cast<WORD>(ch);
    up.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
    inputs.push_back(up);
  }
  SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
}

inline void SetClipboardUnicodeText(const std::string& utf8_text) {
  std::wstring wtext = Utf8ToWide(utf8_text);
  if (!OpenClipboard(nullptr)) return;
  EmptyClipboard();
  size_t bytes = (wtext.size() + 1) * sizeof(wchar_t);
  HGLOBAL h_mem = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (h_mem != nullptr) {
    void* ptr = GlobalLock(h_mem);
    if (ptr != nullptr) {
      memcpy(ptr, wtext.c_str(), bytes);
      GlobalUnlock(h_mem);
      SetClipboardData(CF_UNICODETEXT, h_mem);
    } else {
      GlobalFree(h_mem);
    }
  }
  CloseClipboard();
}

inline bool SendKeyboardShortcutSpec(const std::string& raw_spec) {
  std::string lower = ToLowerAscii(raw_spec);
  if (lower.rfind("shortcut:", 0) == 0) {
    lower = lower.substr(9);
  }
  WORD mod1 = 0;
  WORD mod2 = 0;
  WORD vk = 0;
  std::vector<std::string> parts;
  std::string cur;
  for (char c : lower) {
    if (c == '+' || c == '-') {
      if (!cur.empty()) {
        parts.push_back(cur);
        cur.clear();
      }
    } else if (!std::isspace(static_cast<unsigned char>(c))) {
      cur.push_back(c);
    }
  }
  if (!cur.empty()) parts.push_back(cur);
  for (const auto& p : parts) {
    if (p == "ctrl" || p == "control" || p == "cmd" || p == "command") {
      if (mod1 == 0)
        mod1 = VK_CONTROL;
      else
        mod2 = VK_CONTROL;
    } else if (p == "alt" || p == "opt" || p == "option") {
      if (mod1 == 0)
        mod1 = VK_MENU;
      else
        mod2 = VK_MENU;
    } else if (p == "shift") {
      if (mod1 == 0)
        mod1 = VK_SHIFT;
      else
        mod2 = VK_SHIFT;
    } else if (p == "enter" || p == "return") {
      vk = VK_RETURN;
    } else if (p == "space") {
      vk = VK_SPACE;
    } else if (p == "esc" || p == "escape") {
      vk = VK_ESCAPE;
    } else if (p == "tab") {
      vk = VK_TAB;
    } else if (p == "backspace" || p == "delete") {
      vk = VK_BACK;
    } else if (p == "up") {
      vk = VK_UP;
    } else if (p == "down") {
      vk = VK_DOWN;
    } else if (p == "left") {
      vk = VK_LEFT;
    } else if (p == "right") {
      vk = VK_RIGHT;
    } else if (p.size() == 1 && std::isalnum(static_cast<unsigned char>(p[0]))) {
      vk = static_cast<WORD>(std::toupper(static_cast<unsigned char>(p[0])));
    }
  }
  if (vk == 0) return false;
  SendKeyChord(mod1, mod2, vk);
  return true;
}

inline bool TryWindowsNativeAppUriAction(HWND hwnd,
                                         const std::string& req_win_title,
                                         const std::string& query,
                                         std::string* out_detail) {
  if (query.empty()) return false;
  std::string app_hint =
      ToLowerAscii(req_win_title + " " + QueryProcessBaseNameForHwnd(hwnd));
  if (app_hint.find("spotify") != std::string::npos) {
    std::string uri = "spotify:search:" + UrlEncodeUtf8Component(query);
    std::wstring wuri = Utf8ToWide(uri);
    HINSTANCE res =
        ShellExecuteW(nullptr, L"open", wuri.c_str(), nullptr, nullptr,
                      SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(res) > 32) {
      Sleep(550);
      if (hwnd != nullptr) {
        SetForegroundWindow(hwnd);
        Sleep(150);
      }
      SendKeyChord(0, 0, VK_RETURN);
      *out_detail = "WIN_URI_SPOTIFY_SEARCH:" + query;
      return true;
    }
  }
  return false;
}

inline bool InvokeWindowsUiaMenuPath(IUIAutomation* uia, HWND hwnd,
                                     const std::string& query,
                                     std::string* out_detail) {
  if (uia == nullptr || hwnd == nullptr || query.empty()) return false;
  IUIAutomationElement* root = nullptr;
  if (FAILED(uia->ElementFromHandle(hwnd, &root)) || root == nullptr) {
    return false;
  }

  std::vector<std::string> path_parts;
  std::string normalized = query;
  size_t pos = 0;
  while ((pos = normalized.find("->")) != std::string::npos) {
    normalized.replace(pos, 2, ">");
  }
  std::string cur;
  for (char ch : normalized) {
    if (ch == '>') {
      std::string trimmed = ToLowerAscii(cur);
      while (!trimmed.empty() &&
             std::isspace(static_cast<unsigned char>(trimmed.front()))) {
        trimmed.erase(trimmed.begin());
      }
      while (!trimmed.empty() &&
             std::isspace(static_cast<unsigned char>(trimmed.back()))) {
        trimmed.pop_back();
      }
      if (!trimmed.empty()) path_parts.push_back(trimmed);
      cur.clear();
    } else {
      cur.push_back(ch);
    }
  }
  {
    std::string trimmed = ToLowerAscii(cur);
    while (!trimmed.empty() &&
           std::isspace(static_cast<unsigned char>(trimmed.front()))) {
      trimmed.erase(trimmed.begin());
    }
    while (!trimmed.empty() &&
           std::isspace(static_cast<unsigned char>(trimmed.back()))) {
      trimmed.pop_back();
    }
    if (!trimmed.empty()) path_parts.push_back(trimmed);
  }
  if (path_parts.empty()) {
    root->Release();
    return false;
  }

  VARIANT var_menu;
  VariantInit(&var_menu);
  var_menu.vt = VT_I4;
  var_menu.lVal = UIA_MenuItemControlTypeId;
  IUIAutomationCondition* menu_cond = nullptr;
  if (FAILED(uia->CreatePropertyCondition(UIA_ControlTypePropertyId, var_menu,
                                          &menu_cond)) ||
      menu_cond == nullptr) {
    root->Release();
    return false;
  }

  bool ok = false;
  std::string matched_chain;
  for (size_t step = 0; step < path_parts.size(); ++step) {
    const std::string& target_step = path_parts[step];
    const bool is_last = (step + 1 == path_parts.size());
    IUIAutomationElementArray* items = nullptr;
    if (FAILED(root->FindAll(TreeScope_Descendants, menu_cond, &items)) ||
        items == nullptr) {
      break;
    }
    int len = 0;
    items->get_Length(&len);
    bool step_matched = false;
    for (int i = 0; i < len; ++i) {
      IUIAutomationElement* item = nullptr;
      if (FAILED(items->GetElement(i, &item)) || item == nullptr) continue;
      BSTR bname = nullptr;
      std::string name;
      if (SUCCEEDED(item->get_CurrentName(&bname)) && bname != nullptr) {
        name = WideToUtf8(std::wstring(bname, SysStringLen(bname)));
        SysFreeString(bname);
      }
      std::string lower_name = ToLowerAscii(name);
      if (!lower_name.empty() &&
          (lower_name == target_step ||
           lower_name.find(target_step) != std::string::npos)) {
        if (!is_last) {
          IUIAutomationExpandCollapsePattern* exp_pat = nullptr;
          if (SUCCEEDED(item->GetCurrentPatternAs(
                  UIA_ExpandCollapsePatternId,
                  __uuidof(IUIAutomationExpandCollapsePattern),
                  reinterpret_cast<void**>(&exp_pat))) &&
              exp_pat != nullptr) {
            exp_pat->Expand();
            exp_pat->Release();
          } else {
            IUIAutomationInvokePattern* inv_pat = nullptr;
            if (SUCCEEDED(item->GetCurrentPatternAs(
                    UIA_InvokePatternId, __uuidof(IUIAutomationInvokePattern),
                    reinterpret_cast<void**>(&inv_pat))) &&
                inv_pat != nullptr) {
              inv_pat->Invoke();
              inv_pat->Release();
            }
          }
          Sleep(140);
          matched_chain += (matched_chain.empty() ? "" : " > ") + name;
          step_matched = true;
        } else {
          IUIAutomationInvokePattern* inv_pat = nullptr;
          if (SUCCEEDED(item->GetCurrentPatternAs(
                  UIA_InvokePatternId, __uuidof(IUIAutomationInvokePattern),
                  reinterpret_cast<void**>(&inv_pat))) &&
              inv_pat != nullptr) {
            if (SUCCEEDED(inv_pat->Invoke())) {
              ok = true;
              step_matched = true;
              matched_chain += (matched_chain.empty() ? "" : " > ") + name;
            }
            inv_pat->Release();
          }
          if (!ok) {
            RECT rc = {};
            if (SUCCEEDED(item->get_CurrentBoundingRectangle(&rc)) &&
                rc.right > rc.left && rc.bottom > rc.top) {
              ClickScreenPoint((rc.left + rc.right) / 2,
                               (rc.top + rc.bottom) / 2);
              ok = true;
              step_matched = true;
              matched_chain += (matched_chain.empty() ? "" : " > ") + name;
            }
          }
        }
        item->Release();
        break;
      }
      item->Release();
    }
    items->Release();
    if (!step_matched) break;
  }

  menu_cond->Release();
  root->Release();
  if (ok) {
    *out_detail = "UIA_MENU_PATH:" + matched_chain;
  }
  return ok;
}

inline bool TryWindowsBrowserDomUiaAction(IUIAutomation* uia, HWND hwnd,
                                          const std::string& action,
                                          const std::string& target_query,
                                          const std::string& value_text,
                                          bool submit,
                                          std::string* out_detail) {
  if (uia == nullptr || hwnd == nullptr) return false;
  IUIAutomationElement* root = nullptr;
  if (FAILED(uia->ElementFromHandle(hwnd, &root)) || root == nullptr) {
    return false;
  }

  VARIANT var_doc;
  VariantInit(&var_doc);
  var_doc.vt = VT_I4;
  var_doc.lVal = UIA_DocumentControlTypeId;
  IUIAutomationCondition* doc_cond = nullptr;
  IUIAutomationElement* doc_root = nullptr;
  if (SUCCEEDED(uia->CreatePropertyCondition(UIA_ControlTypePropertyId, var_doc,
                                             &doc_cond)) &&
      doc_cond != nullptr) {
    root->FindFirst(TreeScope_Descendants, doc_cond, &doc_root);
    doc_cond->Release();
  }
  IUIAutomationElement* search_scope = doc_root != nullptr ? doc_root : root;

  IUIAutomationCondition* true_cond = nullptr;
  if (FAILED(uia->CreateTrueCondition(&true_cond)) || true_cond == nullptr) {
    if (doc_root != nullptr) doc_root->Release();
    root->Release();
    return false;
  }

  IUIAutomationElementArray* arr = nullptr;
  bool ok = false;
  std::string needle = ToLowerAscii(target_query);
  if (SUCCEEDED(search_scope->FindAll(TreeScope_Descendants, true_cond, &arr)) &&
      arr != nullptr) {
    int len = 0;
    arr->get_Length(&len);
    for (int i = 0; i < len && i < 350; ++i) {
      IUIAutomationElement* el = nullptr;
      if (FAILED(arr->GetElement(i, &el)) || el == nullptr) continue;
      CONTROLTYPEID ctrl_type = 0;
      el->get_CurrentControlType(&ctrl_type);
      BSTR bname = nullptr;
      std::string name;
      if (SUCCEEDED(el->get_CurrentName(&bname)) && bname != nullptr) {
        name = WideToUtf8(std::wstring(bname, SysStringLen(bname)));
        SysFreeString(bname);
      }
      if (name.empty()) {
        BSTR bhelp = nullptr;
        if (SUCCEEDED(el->get_CurrentHelpText(&bhelp)) && bhelp != nullptr) {
          name = WideToUtf8(std::wstring(bhelp, SysStringLen(bhelp)));
          SysFreeString(bhelp);
        }
      }
      std::string lower_name = ToLowerAscii(name);
      if (action == "browser_type") {
        bool is_input = (ctrl_type == UIA_EditControlTypeId ||
                         ctrl_type == UIA_ComboBoxControlTypeId);
        if (is_input &&
            (needle.empty() || lower_name.find(needle) != std::string::npos)) {
          el->SetFocus();
          IUIAutomationValuePattern* val_pat = nullptr;
          if (SUCCEEDED(el->GetCurrentPatternAs(
                  UIA_ValuePatternId, __uuidof(IUIAutomationValuePattern),
                  reinterpret_cast<void**>(&val_pat))) &&
              val_pat != nullptr) {
            std::wstring wval = Utf8ToWide(value_text);
            BSTR bval = SysAllocString(wval.c_str());
            if (bval != nullptr) {
              if (SUCCEEDED(val_pat->SetValue(bval))) {
                ok = true;
                *out_detail = "BROWSER_DOM_TYPED:" + name;
                if (submit) {
                  Sleep(80);
                  SendKeyChord(0, 0, VK_RETURN);
                }
              }
              SysFreeString(bval);
            }
            val_pat->Release();
          }
          if (ok) {
            el->Release();
            break;
          }
        }
      } else {
        bool is_clickable = (ctrl_type == UIA_ButtonControlTypeId ||
                             ctrl_type == UIA_HyperlinkControlTypeId ||
                             ctrl_type == UIA_MenuItemControlTypeId ||
                             ctrl_type == UIA_TabItemControlTypeId ||
                             ctrl_type == UIA_ListItemControlTypeId);
        if (is_clickable && !needle.empty() &&
            lower_name.find(needle) != std::string::npos) {
          IUIAutomationInvokePattern* inv_pat = nullptr;
          if (SUCCEEDED(el->GetCurrentPatternAs(
                  UIA_InvokePatternId, __uuidof(IUIAutomationInvokePattern),
                  reinterpret_cast<void**>(&inv_pat))) &&
              inv_pat != nullptr) {
            if (SUCCEEDED(inv_pat->Invoke())) {
              ok = true;
              *out_detail = "BROWSER_DOM_CLICKED:" + name;
            }
            inv_pat->Release();
          }
          if (!ok) {
            RECT rc = {};
            if (SUCCEEDED(el->get_CurrentBoundingRectangle(&rc)) &&
                rc.right > rc.left && rc.bottom > rc.top) {
              ClickScreenPoint((rc.left + rc.right) / 2,
                               (rc.top + rc.bottom) / 2);
              ok = true;
              *out_detail = "BROWSER_DOM_COORD_CLICKED:" + name;
            }
          }
          if (ok) {
            el->Release();
            break;
          }
        }
      }
      el->Release();
    }
    arr->Release();
  }

  true_cond->Release();
  if (doc_root != nullptr) doc_root->Release();
  root->Release();
  return ok;
}

inline void ExecuteInvokeWindowUiControl(
    const flutter::EncodableMap& args,
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* ref_val = FindKey(args, "refId");
  const auto* ref_str = ref_val ? std::get_if<std::string>(ref_val) : nullptr;
  std::string target_ref = ref_str ? *ref_str : "ui_1";
  const auto* act_val = FindKey(args, "action");
  const auto* act_str = act_val ? std::get_if<std::string>(act_val) : nullptr;
  std::string action = act_str ? *act_str : "invoke_ref";
  const auto* val_val = FindKey(args, "valueText");
  const auto* val_str = val_val ? std::get_if<std::string>(val_val) : nullptr;
  std::string value_text = val_str ? *val_str : "";
  const auto* wt_val = FindKey(args, "windowTitle");
  const auto* wt_str = wt_val ? std::get_if<std::string>(wt_val) : nullptr;
  std::string req_win_title = wt_str ? *wt_str : "";
  bool submit = true;
  if (const auto* sub_val = FindKey(args, "submit")) {
    if (const auto* b = std::get_if<bool>(sub_val)) submit = *b;
  }

  HWND hwnd = ResolveTargetWindow(req_win_title, true);
  if (IsHardDeniedOrElevatedHwnd(hwnd)) {
    flutter::EncodableMap out;
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
    out[flutter::EncodableValue("invokedRefId")] =
        flutter::EncodableValue(target_ref);
    out[flutter::EncodableValue("detail")] =
        flutter::EncodableValue("HARD_DENIED_OR_ELEVATED_WINDOW");
    out[flutter::EncodableValue("windowTitle")] =
        flutter::EncodableValue(QueryProcessBaseNameForHwnd(hwnd));
    out[flutter::EncodableValue("nodes")] =
        flutter::EncodableValue(flutter::EncodableList());
    out[flutter::EncodableValue("screenshotBytesUsed")] =
        flutter::EncodableValue(0);
    result->Success(flutter::EncodableValue(out));
    return;
  }
  bool applied = false;
  std::string detail = "FALLBACK";

  std::string lower_act = ToLowerAscii(action);
  std::string lower_ref = ToLowerAscii(target_ref);
  std::string lower_val = ToLowerAscii(value_text);
  if (lower_act == "shortcut" || lower_ref.rfind("shortcut:", 0) == 0 ||
      lower_val.rfind("shortcut:", 0) == 0) {
    std::string spec =
        lower_ref.rfind("shortcut:", 0) == 0
            ? lower_ref
            : (lower_val.empty() ? lower_ref : lower_val);
    if (SendKeyboardShortcutSpec(spec)) {
      applied = true;
      detail = "SHORTCUT:" + spec;
    }
  } else if (lower_act == "bring_to_front" || lower_act == "focus_window") {
    if (hwnd != nullptr) {
      if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
      SetForegroundWindow(hwnd);
      applied = true;
      detail = "BROUGHT_TO_FRONT";
    }
  } else if (lower_act == "close_window" || lower_act == "kill_app") {
    if (hwnd != nullptr) {
      PostMessageW(hwnd, WM_CLOSE, 0, 0);
      applied = true;
      detail = "WINDOW_CLOSED";
    }
  } else if (!value_text.empty() &&
             (lower_act == "set_value_ref" ||
              lower_act == "native_script_action")) {
    std::string uri_detail;
    if (TryWindowsNativeAppUriAction(hwnd, req_win_title, value_text,
                                     &uri_detail)) {
      applied = true;
      detail = uri_detail;
    }
  }

  int target_idx = 0;
  if (!applied && target_ref.rfind("ui_", 0) == 0 && target_ref.size() > 3) {
    target_idx = std::atoi(target_ref.substr(3).c_str());
  }

  int target_cx = -1;
  int target_cy = -1;
  IUIAutomation* uia = nullptr;
  if (!applied && hwnd != nullptr &&
      SUCCEEDED(CoCreateInstance(__uuidof(CUIAutomation), nullptr,
                                 CLSCTX_INPROC_SERVER,
                                 __uuidof(IUIAutomation),
                                 reinterpret_cast<void**>(&uia))) &&
      uia != nullptr) {
    if (lower_act == "invoke_menu") {
      std::string menu_query = value_text.empty() ? target_ref : value_text;
      std::string menu_detail;
      if (InvokeWindowsUiaMenuPath(uia, hwnd, menu_query, &menu_detail)) {
        applied = true;
        detail = menu_detail;
      }
    } else if (lower_act == "browser_click" || lower_act == "browser_type") {
      std::string dom_detail;
      if (TryWindowsBrowserDomUiaAction(uia, hwnd, lower_act, target_ref,
                                        value_text, submit, &dom_detail)) {
        applied = true;
        detail = dom_detail;
      }
    }

    std::vector<InteractiveUiaNode> items;
    int redacted_dummy = 0;
    if (!applied) {
      CollectInteractiveUiaNodes(uia, hwnd, 60, true, &items, &redacted_dummy);
    }

    if (!applied && lower_act.rfind("scroll", 0) == 0) {
      std::string dir = lower_val.empty() ? lower_act : lower_val;
      int sx = -1, sy = -1;
      if (target_idx >= 1 && target_idx <= static_cast<int>(items.size())) {
        sx = items[target_idx - 1].center_x;
        sy = items[target_idx - 1].center_y;
      }
      PostMouseScrollWheel(dir, 5, sx, sy);
      applied = true;
      detail = "SCROLLED:" + dir;
    } else if (!applied &&
               (lower_act == "drag" || lower_act == "left_click_drag")) {
      int x1 = 400, y1 = 400, x2 = 560, y2 = 400;
      if (sscanf_s(value_text.c_str(), "%d,%d->%d,%d", &x1, &y1, &x2, &y2) !=
          4) {
        if (target_idx >= 1 && target_idx <= static_cast<int>(items.size()) &&
            items[target_idx - 1].center_x >= 0) {
          x1 = items[target_idx - 1].center_x;
          y1 = items[target_idx - 1].center_y;
        }
        if (value_text.rfind("ui_", 0) == 0 && value_text.size() > 3) {
          int dst_idx = std::atoi(value_text.substr(3).c_str());
          if (dst_idx >= 1 && dst_idx <= static_cast<int>(items.size()) &&
              items[dst_idx - 1].center_x >= 0) {
            x2 = items[dst_idx - 1].center_x;
            y2 = items[dst_idx - 1].center_y;
          }
        }
      }
      PostMouseDragScreenPoints(x1, y1, x2, y2, 24);
      applied = true;
      detail = "DRAGGED";
    }

    InteractiveUiaNode* chosen = nullptr;
    auto is_editable_role = [](const std::string& role) {
      return role == "AXTextField" || role == "AXComboBox" ||
             role == "AXTextArea" || role == "AXSearchField";
    };
    if (!applied && target_idx >= 1 &&
        target_idx <= static_cast<int>(items.size())) {
      InteractiveUiaNode* candidate = &items[target_idx - 1];
      if (candidate->is_password) {
        detail = "REFUSED_PASSWORD_CONTROL";
      } else if (action != "set_value_ref" || is_editable_role(candidate->role)) {
        chosen = candidate;
      }
    }
    if (!applied && chosen == nullptr && action == "set_value_ref") {
      for (auto& item : items) {
        if (is_editable_role(item.role)) {
          chosen = &item;
          break;
        }
      }
    }
    if (!applied && chosen == nullptr && action != "set_value_ref") {
      std::string needle =
          ToLowerAscii(value_text.empty() ? target_ref : value_text);
      if (!needle.empty()) {
        for (auto& item : items) {
          if (ToLowerAscii(item.label).find(needle) != std::string::npos) {
            chosen = &item;
            break;
          }
        }
      }
    }

    if (!applied && chosen != nullptr && chosen->element != nullptr) {
      IUIAutomationElement* el = chosen->element;
      target_cx = chosen->center_x;
      target_cy = chosen->center_y;
      el->SetFocus();
      if (lower_act == "double_click" || lower_act == "triple_click" ||
          lower_act == "right_click" || lower_act == "middle_click" ||
          lower_act == "mouse_move" || lower_act == "hover_ref") {
        if (target_cx >= 0 && target_cy >= 0) {
          if (lower_act == "mouse_move" || lower_act == "hover_ref") {
            SetCursorPos(target_cx, target_cy);
          } else if (lower_act == "right_click") {
            PostMouseClickScreenPoint(target_cx, target_cy, "right", 1);
          } else if (lower_act == "middle_click") {
            PostMouseClickScreenPoint(target_cx, target_cy, "middle", 1);
          } else if (lower_act == "triple_click") {
            PostMouseClickScreenPoint(target_cx, target_cy, "left", 3);
          } else {
            PostMouseClickScreenPoint(target_cx, target_cy, "left", 2);
          }
          applied = true;
          detail = "UIA_POINTER_" + lower_act + ":" + chosen->label;
        }
      } else if (action == "set_value_ref" && !value_text.empty()) {
        IUIAutomationValuePattern* val_pat = nullptr;
        if (SUCCEEDED(el->GetCurrentPatternAs(
                UIA_ValuePatternId, __uuidof(IUIAutomationValuePattern),
                reinterpret_cast<void**>(&val_pat))) &&
            val_pat != nullptr) {
          std::wstring wval = Utf8ToWide(value_text);
          BSTR bval = SysAllocString(wval.c_str());
          if (bval != nullptr) {
            if (SUCCEEDED(val_pat->SetValue(bval))) {
              Sleep(90);
              BSTR bread = nullptr;
              std::string read_back;
              if (SUCCEEDED(val_pat->get_CurrentValue(&bread)) &&
                  bread != nullptr) {
                read_back =
                    WideToUtf8(std::wstring(bread, SysStringLen(bread)));
                SysFreeString(bread);
              }
              if (ToLowerAscii(read_back).find(ToLowerAscii(value_text)) !=
                  std::string::npos) {
                applied = true;
                detail = "VERIFIED_UIA_VALUE_SET:" + chosen->label;
                if (submit) {
                  Sleep(100);
                  SendKeyChord(0, 0, VK_RETURN);
                }
              }
            }
            SysFreeString(bval);
          }
          val_pat->Release();
        }
      } else {
        IUIAutomationInvokePattern* inv_pat = nullptr;
        if (SUCCEEDED(el->GetCurrentPatternAs(
                UIA_InvokePatternId, __uuidof(IUIAutomationInvokePattern),
                reinterpret_cast<void**>(&inv_pat))) &&
            inv_pat != nullptr) {
          if (SUCCEEDED(inv_pat->Invoke())) {
            applied = true;
            detail = "UIA_INVOKED:" + chosen->label;
          }
          inv_pat->Release();
        }
        if (!applied) {
          IUIAutomationSelectionItemPattern* sel_pat = nullptr;
          if (SUCCEEDED(el->GetCurrentPatternAs(
                  UIA_SelectionItemPatternId,
                  __uuidof(IUIAutomationSelectionItemPattern),
                  reinterpret_cast<void**>(&sel_pat))) &&
              sel_pat != nullptr) {
            if (SUCCEEDED(sel_pat->Select())) {
              applied = true;
              detail = "UIA_SELECTED:" + chosen->label;
            }
            sel_pat->Release();
          }
        }
        if (!applied) {
          IUIAutomationTogglePattern* tog_pat = nullptr;
          if (SUCCEEDED(el->GetCurrentPatternAs(
                  UIA_TogglePatternId, __uuidof(IUIAutomationTogglePattern),
                  reinterpret_cast<void**>(&tog_pat))) &&
              tog_pat != nullptr) {
            if (SUCCEEDED(tog_pat->Toggle())) {
              applied = true;
              detail = "UIA_TOGGLED:" + chosen->label;
            }
            tog_pat->Release();
          }
        }
        if (!applied) {
          IUIAutomationExpandCollapsePattern* exp_pat = nullptr;
          if (SUCCEEDED(el->GetCurrentPatternAs(
                  UIA_ExpandCollapsePatternId,
                  __uuidof(IUIAutomationExpandCollapsePattern),
                  reinterpret_cast<void**>(&exp_pat))) &&
              exp_pat != nullptr) {
            if (SUCCEEDED(exp_pat->Expand())) {
              applied = true;
              detail = "UIA_EXPANDED:" + chosen->label;
            }
            exp_pat->Release();
          }
        }
        if (!applied && target_cx >= 0 && target_cy >= 0) {
          SetForegroundWindow(hwnd);
          Sleep(60);
          ClickScreenPoint(target_cx, target_cy);
          applied = true;
          detail = "ESCALATED_UIA_COORD_CLICK:" + chosen->label;
        }
      }
    } else if (!applied && !value_text.empty() && action != "set_value_ref") {
      std::string menu_detail;
      if (InvokeWindowsUiaMenuPath(uia, hwnd, value_text, &menu_detail)) {
        applied = true;
        detail = menu_detail;
      }
    }

    for (auto& item : items) {
      if (item.element != nullptr) {
        item.element->Release();
      }
    }
    uia->Release();
  }

  // Fallback for set_value_ref when ValuePattern is unsupported
  if (!applied && detail != "REFUSED_PASSWORD_CONTROL" && !value_text.empty()) {
    if (target_cx >= 0 && target_cy >= 0) {
      ClickScreenPoint(target_cx, target_cy);
      Sleep(100);
    } else {
      SendKeyChord(VK_CONTROL, 0, 'F');
      Sleep(200);
    }
    SendKeyChord(VK_CONTROL, 0, 'A');
    Sleep(50);
    SendKeyChord(0, 0, VK_BACK);
    Sleep(50);
    SetClipboardUnicodeText(value_text);
    SendKeyChord(VK_CONTROL, 0, 'V');
    Sleep(60);
    if (action == "type_unicode") {
      SendUnicodeTextInput(value_text);
    }
    if (submit) {
      Sleep(120);
      SendKeyChord(0, 0, VK_RETURN);
    }
    applied = true;
    detail = "CLIPBOARD_PASTED";
  }

  Sleep(450);
  HWND post_hwnd = ResolveTargetWindow(req_win_title, false);
  flutter::EncodableList updated_nodes;
  int updated_redacted = 0;
  std::string updated_title;
  std::string updated_app;
  ScanWindowUiTreeToEncodable(post_hwnd, 40, &updated_nodes, &updated_redacted,
                              &updated_title, &updated_app);

  flutter::EncodableMap out;
  out[flutter::EncodableValue("ok")] = flutter::EncodableValue(applied);
  out[flutter::EncodableValue("invokedRefId")] =
      flutter::EncodableValue(target_ref);
  out[flutter::EncodableValue("detail")] = flutter::EncodableValue(detail);
  out[flutter::EncodableValue("windowTitle")] =
      flutter::EncodableValue(updated_title);
  out[flutter::EncodableValue("nodes")] =
      flutter::EncodableValue(updated_nodes);
  out[flutter::EncodableValue("screenshotBytesUsed")] =
      flutter::EncodableValue(0);
  result->Success(flutter::EncodableValue(out));
}

}  // namespace xuna_win

#endif  // RUNNER_XUNA_WIN_UIA_ENGINE_H_
