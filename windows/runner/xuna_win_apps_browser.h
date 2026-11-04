#ifndef RUNNER_XUNA_WIN_APPS_BROWSER_H_
#define RUNNER_XUNA_WIN_APPS_BROWSER_H_

#include "xuna_win_common.h"

namespace xuna_win {

inline void ScanDirectoryForShortcutsOrExes(
    const std::wstring& dir_path, int depth, int max_depth,
    const std::string& query_lower, const std::string& query_compact,
    const std::vector<std::string>& query_tokens, int* best_score,
    std::wstring* best_path) {
  if (depth > max_depth || dir_path.empty()) return;
  std::wstring pattern = dir_path + L"\\*";
  WIN32_FIND_DATAW fd = {};
  HANDLE h_find = FindFirstFileW(pattern.c_str(), &fd);
  if (h_find == INVALID_HANDLE_VALUE) return;
  do {
    std::wstring name(fd.cFileName);
    if (name == L"." || name == L"..") continue;
    std::wstring full = dir_path + L"\\" + name;
    if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      if (depth < max_depth) {
        ScanDirectoryForShortcutsOrExes(full, depth + 1, max_depth, query_lower,
                                        query_compact, query_tokens, best_score,
                                        best_path);
      }
    } else {
      std::string utf8_name = WideToUtf8(name);
      std::string lower_name = ToLowerAscii(utf8_name);
      bool is_lnk = lower_name.size() > 4 &&
                    lower_name.substr(lower_name.size() - 4) == ".lnk";
      bool is_exe = lower_name.size() > 4 &&
                    lower_name.substr(lower_name.size() - 4) == ".exe";
      if (!is_lnk && !is_exe) continue;
      if (lower_name.find("unins") != std::string::npos ||
          lower_name == "update.exe" || lower_name == "squirrel.exe" ||
          lower_name == "crashpad_handler.exe") {
        continue;
      }
      std::string stem = utf8_name.substr(0, utf8_name.size() - 4);
      int score =
          ScoreCandidateName(stem, query_lower, query_compact, query_tokens);
      if (score > *best_score) {
        *best_score = score;
        *best_path = full;
      }
    }
  } while (FindNextFileW(h_find, &fd) != 0);
  FindClose(h_find);
}

inline std::wstring GetEnvWide(const wchar_t* name) {
  wchar_t buf[MAX_PATH] = {};
  DWORD len = GetEnvironmentVariableW(name, buf, MAX_PATH);
  if (len > 0 && len < MAX_PATH) {
    return std::wstring(buf, len);
  }
  return std::wstring();
}

inline bool DiscoverInstalledWindowsAppTarget(const std::string& query,
                                              std::wstring* out_path) {
  std::string query_lower = ToLowerAscii(query);
  std::string query_compact = CompactAlphaNumLower(query);
  std::vector<std::string> query_tokens = SplitAlphaNumTokens(query);
  if (query_compact.empty()) return false;

  int best_score = 0;
  std::wstring best_path;

  // 1. Check Registry App Paths (HKCU & HKLM)
  const HKEY roots[] = {HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
  for (HKEY root : roots) {
    HKEY h_app_paths = nullptr;
    if (RegOpenKeyExW(
            root,
            L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths", 0,
            KEY_READ, &h_app_paths) == ERROR_SUCCESS &&
        h_app_paths != nullptr) {
      DWORD idx = 0;
      wchar_t subkey_name[256] = {};
      DWORD subkey_len = 256;
      while (RegEnumKeyExW(h_app_paths, idx++, subkey_name, &subkey_len,
                           nullptr, nullptr, nullptr,
                           nullptr) == ERROR_SUCCESS) {
        std::string key_utf8 = WideToUtf8(std::wstring(subkey_name, subkey_len));
        std::string stem = key_utf8;
        if (stem.size() > 4 &&
            ToLowerAscii(stem.substr(stem.size() - 4)) == ".exe") {
          stem = stem.substr(0, stem.size() - 4);
        }
        int score =
            ScoreCandidateName(stem, query_lower, query_compact, query_tokens);
        if (score > best_score) {
          wchar_t val_buf[MAX_PATH] = {};
          LONG val_bytes = sizeof(val_buf);
          if (RegQueryValueW(h_app_paths, subkey_name, val_buf, &val_bytes) ==
                  ERROR_SUCCESS &&
              val_buf[0] != L'\0') {
            std::wstring candidate(val_buf);
            if (!candidate.empty() && candidate.front() == L'"' &&
                candidate.back() == L'"' && candidate.size() >= 2) {
              candidate = candidate.substr(1, candidate.size() - 2);
            }
            best_score = score;
            best_path = candidate;
          }
        }
        subkey_len = 256;
      }
      RegCloseKey(h_app_paths);
    }
  }

  // 2. Scan Start Menu, Desktop, and %LOCALAPPDATA%\Programs
  std::wstring prog_data = GetEnvWide(L"ProgramData");
  std::wstring app_data = GetEnvWide(L"APPDATA");
  std::wstring local_app_data = GetEnvWide(L"LOCALAPPDATA");
  std::wstring user_profile = GetEnvWide(L"USERPROFILE");
  std::vector<std::pair<std::wstring, int>> scan_roots;
  if (!prog_data.empty()) {
    scan_roots.push_back(
        {prog_data + L"\\Microsoft\\Windows\\Start Menu\\Programs", 3});
  }
  if (!app_data.empty()) {
    scan_roots.push_back(
        {app_data + L"\\Microsoft\\Windows\\Start Menu\\Programs", 3});
  }
  if (!user_profile.empty()) {
    scan_roots.push_back({user_profile + L"\\Desktop", 1});
  }
  if (!local_app_data.empty()) {
    scan_roots.push_back({local_app_data + L"\\Programs", 2});
  }
  for (const auto& entry : scan_roots) {
    ScanDirectoryForShortcutsOrExes(entry.first, 0, entry.second, query_lower,
                                    query_compact, query_tokens, &best_score,
                                    &best_path);
  }

  if (best_score >= 25 && !best_path.empty()) {
    *out_path = best_path;
    return true;
  }
  return false;
}

inline bool LaunchAppOrWorkflow(const std::string& kind,
                                const std::string& target) {
  std::wstring wtarget = Utf8ToWide(target);
  if (wtarget.empty()) return false;

  if (kind == "aumid") {
    IApplicationActivationManager* mgr = nullptr;
    HRESULT hr = CoCreateInstance(
        CLSID_ApplicationActivationManager, nullptr, CLSCTX_LOCAL_SERVER,
        IID_PPV_ARGS(&mgr));
    if (SUCCEEDED(hr) && mgr != nullptr) {
      DWORD pid = 0;
      hr = mgr->ActivateApplication(wtarget.c_str(), nullptr, AO_NONE, &pid);
      mgr->Release();
      if (SUCCEEDED(hr)) return true;
    }
    std::wstring explorer_arg = L"shell:AppsFolder\\" + wtarget;
    SHELLEXECUTEINFOW sei = {sizeof(sei)};
    sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    sei.lpVerb = L"open";
    sei.lpFile = explorer_arg.c_str();
    sei.nShow = SW_SHOWNORMAL;
    return ShellExecuteExW(&sei) == TRUE;
  }

  SHELLEXECUTEINFOW sei = {sizeof(sei)};
  sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  sei.lpVerb = L"open";
  sei.lpFile = wtarget.c_str();
  sei.lpParameters = nullptr;
  sei.nShow = SW_SHOWNORMAL;
  if (ShellExecuteExW(&sei) == TRUE) {
    return true;
  }

  std::wstring discovered;
  if (DiscoverInstalledWindowsAppTarget(target, &discovered)) {
    SHELLEXECUTEINFOW retry_sei = {sizeof(retry_sei)};
    retry_sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    retry_sei.lpVerb = L"open";
    retry_sei.lpFile = discovered.c_str();
    retry_sei.lpParameters = nullptr;
    retry_sei.nShow = SW_SHOWNORMAL;
    return ShellExecuteExW(&retry_sei) == TRUE;
  }
  return false;
}

inline bool OpenHttpsUrl(const std::string& url) {
  if (url.rfind("https://", 0) != 0 && url.rfind("HTTPS://", 0) != 0) {
    return false;
  }
  std::wstring wurl = Utf8ToWide(url);
  if (wurl.empty()) return false;
  SHELLEXECUTEINFOW sei = {sizeof(sei)};
  sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  sei.lpVerb = L"open";
  sei.lpFile = wurl.c_str();
  sei.nShow = SW_SHOWNORMAL;
  return ShellExecuteExW(&sei) == TRUE;
}

inline std::string UrlEncodeUtf8Component(const std::string& value) {
  static const char* kHex = "0123456789ABCDEF";
  std::string out;
  out.reserve(value.size() * 3);
  for (unsigned char ch : value) {
    if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
        (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' ||
        ch == '~') {
      out.push_back(static_cast<char>(ch));
    } else {
      out.push_back('%');
      out.push_back(kHex[(ch >> 4) & 0x0F]);
      out.push_back(kHex[ch & 0x0F]);
    }
  }
  return out;
}

inline bool QueryBrowserCurrentUrlUia(const std::string& requested_browser,
                                      std::string* out_url,
                                      std::string* out_browser) {
  IUIAutomation* uia = nullptr;
  HRESULT hr = CoCreateInstance(__uuidof(CUIAutomation), nullptr,
                                CLSCTX_INPROC_SERVER,
                                __uuidof(IUIAutomation),
                                reinterpret_cast<void**>(&uia));
  if (FAILED(hr) || uia == nullptr) {
    return false;
  }

  HWND hwnd = GetForegroundWindow();
  wchar_t class_name[128] = {};
  if (hwnd != nullptr) {
    GetClassNameW(hwnd, class_name, 128);
  }
  if (wcscmp(class_name, L"Chrome_WidgetWin_1") != 0) {
    hwnd = FindWindowW(L"Chrome_WidgetWin_1", nullptr);
  }
  if (hwnd == nullptr) {
    uia->Release();
    return false;
  }

  wchar_t title_buf[512] = {};
  GetWindowTextW(hwnd, title_buf, 512);
  std::string win_title = ToLowerAscii(WideToUtf8(std::wstring(title_buf)));
  std::string detected_browser =
      win_title.find("edge") != std::string::npos ? "edge" : "chrome";
  if (requested_browser != "auto" && !requested_browser.empty() &&
      requested_browser != detected_browser) {
    detected_browser = requested_browser;
  }

  IUIAutomationElement* root = nullptr;
  hr = uia->ElementFromHandle(hwnd, &root);
  if (FAILED(hr) || root == nullptr) {
    uia->Release();
    return false;
  }

  VARIANT var_prop;
  VariantInit(&var_prop);
  var_prop.vt = VT_I4;
  var_prop.lVal = UIA_EditControlTypeId;
  IUIAutomationCondition* edit_cond = nullptr;
  hr = uia->CreatePropertyCondition(UIA_ControlTypePropertyId, var_prop,
                                    &edit_cond);
  if (FAILED(hr) || edit_cond == nullptr) {
    root->Release();
    uia->Release();
    return false;
  }

  IUIAutomationElementArray* edits = nullptr;
  hr = root->FindAll(TreeScope_Descendants, edit_cond, &edits);
  edit_cond->Release();
  root->Release();
  if (FAILED(hr) || edits == nullptr) {
    uia->Release();
    return false;
  }

  int length = 0;
  edits->get_Length(&length);
  bool found = false;
  for (int i = 0; i < length; ++i) {
    IUIAutomationElement* elem = nullptr;
    if (FAILED(edits->GetElement(i, &elem)) || elem == nullptr) continue;
    IUIAutomationValuePattern* val_pat = nullptr;
    if (SUCCEEDED(elem->GetCurrentPatternAs(
            UIA_ValuePatternId, __uuidof(IUIAutomationValuePattern),
            reinterpret_cast<void**>(&val_pat))) &&
        val_pat != nullptr) {
      BSTR bval = nullptr;
      if (SUCCEEDED(val_pat->get_CurrentValue(&bval)) && bval != nullptr) {
        std::string candidate = WideToUtf8(std::wstring(bval, SysStringLen(bval)));
        SysFreeString(bval);
        if (candidate.rfind("https://", 0) == 0 ||
            candidate.rfind("HTTPS://", 0) == 0) {
          *out_url = candidate;
          *out_browser = detected_browser;
          found = true;
        }
      }
      val_pat->Release();
    }
    elem->Release();
    if (found) break;
  }

  edits->Release();
  uia->Release();
  return found;
}

inline std::string QueryWindowsOsVersion() {
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (ntdll != nullptr) {
    auto fn = reinterpret_cast<RtlGetVersionFn>(
        GetProcAddress(ntdll, "RtlGetVersion"));
    if (fn != nullptr) {
      RTL_OSVERSIONINFOW rovi = {};
      rovi.dwOSVersionInfoSize = sizeof(rovi);
      if (fn(&rovi) == 0) {
        return std::to_string(rovi.dwMajorVersion) + "." +
               std::to_string(rovi.dwMinorVersion) + "." +
               std::to_string(rovi.dwBuildNumber);
      }
    }
  }
  return "10.0.0";
}

inline std::string QueryHostname() {
  wchar_t buf[MAX_COMPUTERNAME_LENGTH + 1] = {};
  DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
  if (GetComputerNameW(buf, &size) && size > 0) {
    return TruncateUtf8(WideToUtf8(std::wstring(buf, size)), 32);
  }
  return "XUNA-PC";
}

inline void ShowWindowsToast(const std::string& title,
                             const std::string& body) {
  std::wstring wtitle = Utf8ToWide(TruncateUtf8(title, 63));
  std::wstring wbody = Utf8ToWide(TruncateUtf8(body, 240));
  if (wtitle.empty()) wtitle = L"XUNA";
  if (wbody.empty()) return;

#if XUNA_HAS_CPPWINRT_TOAST
  try {
    using winrt::Windows::Data::Xml::Dom::XmlDocument;
    using winrt::Windows::UI::Notifications::ToastNotification;
    using winrt::Windows::UI::Notifications::ToastNotificationManager;
    using winrt::Windows::UI::Notifications::ToastTemplateType;

    XmlDocument xml = ToastNotificationManager::GetTemplateContent(
        ToastTemplateType::ToastText02);
    auto text_nodes = xml.GetElementsByTagName(L"text");
    if (text_nodes.Length() >= 2) {
      text_nodes.Item(0).AppendChild(xml.CreateTextNode(wtitle));
      text_nodes.Item(1).AppendChild(xml.CreateTextNode(wbody));
      ToastNotification toast(xml);
      ToastNotificationManager::CreateToastNotifier(L"Xuna.Desktop")
          .Show(toast);
      return;
    }
  } catch (...) {
    // Fall back to Win32 Shell_NotifyIconW balloon.
  }
#endif

  HWND hwnd = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
  if (hwnd == nullptr) {
    return;
  }

  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = hwnd;
  nid.uID = 0x58554E41;  // 'XUNA'
  nid.uFlags = NIF_ICON | NIF_TIP | NIF_INFO;
  nid.dwInfoFlags = NIIF_INFO | NIIF_NOSOUND;
  nid.hIcon = LoadIconW(nullptr, IDI_INFORMATION);
  wcsncpy_s(nid.szTip, L"XUNA Desktop Companion", _TRUNCATE);
  wcsncpy_s(nid.szInfoTitle, wtitle.c_str(), _TRUNCATE);
  wcsncpy_s(nid.szInfo, wbody.c_str(), _TRUNCATE);

  if (!Shell_NotifyIconW(NIM_MODIFY, &nid)) {
    Shell_NotifyIconW(NIM_ADD, &nid);
  }
}

}  // namespace xuna_win

#endif  // RUNNER_XUNA_WIN_APPS_BROWSER_H_
