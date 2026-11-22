#ifndef RUNNER_XUNA_WIN_APPS_BROWSER_H_
#define RUNNER_XUNA_WIN_APPS_BROWSER_H_

#include "xuna_win_common.h"

namespace xuna_win {

inline std::string TrimQuotesAndSpacesAscii(const std::string& raw) {
  std::string s = raw;
  auto is_trim = [](unsigned char ch) {
    return std::isspace(ch) || ch == '"' || ch == '\'';
  };
  while (!s.empty() && is_trim(static_cast<unsigned char>(s.front()))) {
    s.erase(s.begin());
  }
  while (!s.empty() && is_trim(static_cast<unsigned char>(s.back()))) {
    s.pop_back();
  }
  return s;
}

inline std::string ExtractFileStemLower(const std::string& raw) {
  std::string s = TrimQuotesAndSpacesAscii(raw);
  size_t slash = s.find_last_of("\\/");
  if (slash != std::string::npos) {
    s = s.substr(slash + 1);
  } else if (s.size() >= 2 &&
             std::isalpha(static_cast<unsigned char>(s[0])) &&
             s[1] == ':') {
    s = s.substr(2);
  }
  size_t ads_colon = s.find(':');
  if (ads_colon != std::string::npos) {
    s = s.substr(0, ads_colon);
  }
  while (!s.empty() &&
         (std::isspace(static_cast<unsigned char>(s.back())) ||
          s.back() == '.' || s.back() == '"' || s.back() == '\'')) {
    s.pop_back();
  }
  s = ToLowerAscii(s);
  bool stripped = true;
  while (stripped) {
    stripped = false;
    for (const char* ext : {".exe", ".lnk", ".cmd", ".bat", ".app",
                            ".com", ".ps1", ".vbs", ".js", ".msc"}) {
      size_t elen = std::strlen(ext);
      if (s.size() > elen && s.compare(s.size() - elen, elen, ext) == 0) {
        s.erase(s.size() - elen);
        while (!s.empty() &&
               (std::isspace(static_cast<unsigned char>(s.back())) ||
                s.back() == '.')) {
          s.pop_back();
        }
        stripped = true;
        break;
      }
    }
  }
  return s;
}

inline bool EndsWithLnkExtension(const std::string& raw) {
  std::string s = TrimQuotesAndSpacesAscii(raw);
  size_t slash = s.find_last_of("\\/");
  std::string last_comp =
      slash != std::string::npos ? s.substr(slash + 1) : s;
  if (slash == std::string::npos && last_comp.size() >= 2 &&
      std::isalpha(static_cast<unsigned char>(last_comp[0])) &&
      last_comp[1] == ':') {
    last_comp = last_comp.substr(2);
  }
  size_t ads_colon = last_comp.find(':');
  if (ads_colon != std::string::npos) {
    last_comp = last_comp.substr(0, ads_colon);
  }
  while (!last_comp.empty() &&
         (std::isspace(static_cast<unsigned char>(last_comp.back())) ||
          last_comp.back() == '.' || last_comp.back() == '"' ||
          last_comp.back() == '\'')) {
    last_comp.pop_back();
  }
  last_comp = ToLowerAscii(last_comp);
  return last_comp.size() > 4 &&
         last_comp.compare(last_comp.size() - 4, 4, ".lnk") == 0;
}

inline bool IsHardDeniedWindowsAppStem(const std::string& raw) {
  std::string cleaned = ToLowerAscii(TrimQuotesAndSpacesAscii(raw));
  if (cleaned.empty()) return true;
  if (cleaned == "%comspec%" ||
      cleaned.find("%comspec%") != std::string::npos) {
    return true;
  }

  size_t bang = cleaned.find('!');
  if (bang != std::string::npos) {
    std::string pkg = cleaned.substr(0, bang);
    size_t ads = pkg.find(':');
    if (ads != std::string::npos) {
      pkg = pkg.substr(0, ads);
    }
    size_t underscore = pkg.find('_');
    std::string pkg_prefix =
        underscore != std::string::npos ? pkg.substr(0, underscore) : pkg;
    static const char* kDeniedAumidPrefixes[] = {
        "microsoft.windowsterminal",
        "microsoft.powershell",
        "1password",
        "bitwarden",
        "keepass",
        "keepassxc",
        "lastpass",
        "dashlane",
        "alacritty",
        "kitty",
        "wezterm",
        "ghostty",
        "hyper",
        "warp",
    };
    for (const char* prefix : kDeniedAumidPrefixes) {
      std::string p(prefix);
      if (pkg_prefix == p ||
          pkg_prefix.rfind(p + ".", 0) == 0 ||
          pkg_prefix.rfind(p + "-", 0) == 0 ||
          pkg_prefix.rfind(p + "preview", 0) == 0 ||
          pkg_prefix.rfind(p + "canary", 0) == 0) {
        return true;
      }
    }
    static const char* kDeniedAumidSubstrings[] = {
        "windowsterminal",
        "1password",
        "bitwarden",
        "keepass",
        "lastpass",
        "dashlane",
    };
    for (const char* sub : kDeniedAumidSubstrings) {
      if (pkg_prefix.find(sub) != std::string::npos) {
        return true;
      }
    }
  }

  std::string stem = ExtractFileStemLower(cleaned);
  if (stem.empty()) return true;
  static const char* kDeniedStems[] = {
      "cmd",          "powershell",      "pwsh",         "wt",
      "windowsterminal", "microsoft.windowsterminal",
      "%comspec%",
      "bash",         "zsh",             "wsl",          "conhost",
      "alacritty",    "kitty",           "wezterm",      "wezterm-gui",
      "ghostty",      "hyper",           "wscript",      "cscript",
      "mshta",        "1password",       "bitwarden",    "keepass",
      "keepassxc",    "lastpass",        "dashlane",     "systemsettings",
      "control",      "regedit",         "mmc",          "taskmgr",
      "secpol",       "gpedit",          "consent",      "credentialuibroker",
      "netplwiz",     "runas",
  };
  for (const char* denied : kDeniedStems) {
    if (stem == denied) return true;
  }
  return false;
}

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
      if (IsHardDeniedWindowsAppStem(stem)) {
        continue;
      }
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
        if (IsHardDeniedWindowsAppStem(stem)) {
          subkey_len = 256;
          continue;
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
            if (!IsHardDeniedWindowsAppStem(WideToUtf8(candidate))) {
              best_score = score;
              best_path = candidate;
            }
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

struct RunningProcessCheckCtx {
  std::string target_stem;
  bool found = false;
};

inline BOOL CALLBACK EnumRunningProcessWindowCb(HWND hwnd, LPARAM lparam) {
  if (!IsWindowVisible(hwnd)) return TRUE;
  auto* ctx = reinterpret_cast<RunningProcessCheckCtx*>(lparam);
  std::string stem = ToLowerAscii(QueryProcessBaseNameForHwnd(hwnd));
  if (!stem.empty() && stem == ctx->target_stem) {
    ctx->found = true;
    return FALSE;
  }
  return TRUE;
}

inline bool IsWindowsTargetAlreadyRunning(const std::string& target) {
  std::string stem = ExtractFileStemLower(target);
  if (stem.empty()) return false;
  RunningProcessCheckCtx ctx{stem, false};
  EnumWindows(EnumRunningProcessWindowCb, reinterpret_cast<LPARAM>(&ctx));
  return ctx.found;
}

inline std::wstring StripExtendedPathPrefix(const std::wstring& path) {
  if (path.rfind(L"\\\\?\\UNC\\", 0) == 0) {
    return L"\\\\" + path.substr(8);
  }
  if (path.rfind(L"\\\\?\\", 0) == 0) {
    return path.substr(4);
  }
  return path;
}

inline bool ResolveFinalWindowsPath(const std::wstring& raw_path,
                                    std::wstring* out_final) {
  wchar_t full_buf[4096] = {};
  DWORD full_len = GetFullPathNameW(raw_path.c_str(), 4096, full_buf, nullptr);
  if (full_len == 0 || full_len >= 4096) return false;
  std::wstring full(full_buf, full_len);
  if (GetFileAttributesW(full.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  HANDLE h = CreateFileW(
      full.c_str(), 0,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (h == INVALID_HANDLE_VALUE) {
    return false;
  }
  wchar_t final_buf[4096] = {};
  DWORD final_len = GetFinalPathNameByHandleW(
      h, final_buf, 4096, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  CloseHandle(h);
  if (final_len == 0 || final_len >= 4096) {
    return false;
  }
  *out_final = StripExtendedPathPrefix(std::wstring(final_buf, final_len));
  return !out_final->empty();
}

inline bool ValidateSafeOpenPathWindows(const std::string& raw_open_path,
                                        std::wstring* out_full_path) {
  if (raw_open_path.empty()) return true;
  if (raw_open_path.find("..") != std::string::npos) return false;
  for (unsigned char ch : raw_open_path) {
    if (ch < 0x20 || ch == 0x7F) return false;
  }
  std::wstring wraw = Utf8ToWide(raw_open_path);
  if (wraw.empty()) return false;
  std::wstring final_target;
  if (!ResolveFinalWindowsPath(wraw, &final_target)) {
    return false;
  }
  std::wstring user_profile = GetEnvWide(L"USERPROFILE");
  if (user_profile.empty()) return false;
  std::wstring home_final;
  if (!ResolveFinalWindowsPath(user_profile, &home_final)) {
    return false;
  }
  std::string final_lower = ToLowerAscii(WideToUtf8(final_target));
  std::string home_lower = ToLowerAscii(WideToUtf8(home_final));
  if (home_lower.empty()) return false;
  if (home_lower.back() != '\\') {
    home_lower.push_back('\\');
  }
  if (final_lower.rfind(home_lower, 0) != 0) {
    return false;
  }
  *out_full_path = final_target;
  return true;
}

inline std::wstring ExpandWindowsEnvVars(const std::wstring& raw) {
  if (raw.empty()) return std::wstring();
  DWORD needed = ExpandEnvironmentStringsW(raw.c_str(), nullptr, 0);
  if (needed == 0 || needed > 32768) {
    return raw;
  }
  std::wstring out(static_cast<size_t>(needed), L'\0');
  DWORD written = ExpandEnvironmentStringsW(raw.c_str(), &out[0], needed);
  if (written == 0 || written > needed) {
    return raw;
  }
  if (!out.empty() && out.back() == L'\0') {
    out.pop_back();
  }
  return out;
}

inline bool ResolveShortcutTargetUtf8(const std::wstring& lnk_path,
                                      std::string* out_target_utf8,
                                      std::string* out_raw_target_utf8 = nullptr) {
  out_target_utf8->clear();
  if (out_raw_target_utf8 != nullptr) {
    out_raw_target_utf8->clear();
  }
  if (GetFileAttributesW(lnk_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  IShellLinkW* psl = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&psl));
  if (FAILED(hr) || psl == nullptr) {
    return false;
  }
  IPersistFile* ppf = nullptr;
  hr = psl->QueryInterface(IID_PPV_ARGS(&ppf));
  bool ok = false;
  if (SUCCEEDED(hr) && ppf != nullptr) {
    if (SUCCEEDED(ppf->Load(lnk_path.c_str(), STGM_READ))) {
      wchar_t raw_buf[4096] = {};
      wchar_t resolved_buf[4096] = {};
      std::wstring raw_w;
      if (SUCCEEDED(psl->GetPath(raw_buf, 4096, nullptr, SLGP_RAWPATH)) &&
          raw_buf[0] != L'\0') {
        raw_w = std::wstring(raw_buf);
        if (out_raw_target_utf8 != nullptr) {
          *out_raw_target_utf8 = WideToUtf8(raw_w);
        }
      }
      std::wstring expanded_w =
          raw_w.empty() ? std::wstring() : ExpandWindowsEnvVars(raw_w);
      if (expanded_w.empty() &&
          SUCCEEDED(psl->GetPath(resolved_buf, 4096, nullptr, 0)) &&
          resolved_buf[0] != L'\0') {
        expanded_w = ExpandWindowsEnvVars(std::wstring(resolved_buf));
      }
      if (!expanded_w.empty()) {
        *out_target_utf8 = WideToUtf8(expanded_w);
        ok = !out_target_utf8->empty();
      } else if (!raw_w.empty()) {
        *out_target_utf8 = WideToUtf8(raw_w);
        ok = !out_target_utf8->empty();
      }
    }
    ppf->Release();
  }
  psl->Release();
  return ok;
}

inline bool LaunchAppOrWorkflow(const std::string& kind,
                                const std::string& target,
                                bool is_workflow = false,
                                const std::string& open_path = "",
                                bool* out_already_running = nullptr,
                                std::string* out_error_code = nullptr,
                                std::string* out_error_msg = nullptr) {
  if (out_already_running) *out_already_running = false;
  if (is_workflow) {
    if (kind != "lnk") {
      if (out_error_code) *out_error_code = "platform_unsupported";
      if (out_error_msg) *out_error_msg = "Only .lnk workflows are supported on Windows";
      return false;
    }
  } else {
    if (kind != "exe" && kind != "aumid" && kind != "lnk") {
      if (out_error_code) *out_error_code = "platform_unsupported";
      if (out_error_msg) *out_error_msg = "Unsupported app kind on Windows";
      return false;
    }
  }
  if (IsHardDeniedWindowsAppStem(target)) {
    if (out_error_code) *out_error_code = "denylisted_target_forbidden";
    if (out_error_msg) *out_error_msg = "Target application is forbidden by policy";
    return false;
  }
  std::wstring safe_open_path;
  if (!open_path.empty() &&
      !ValidateSafeOpenPathWindows(open_path, &safe_open_path)) {
    if (out_error_code) *out_error_code = "policy_blocked";
    if (out_error_msg) *out_error_msg = "openPath must exist inside user profile directory";
    return false;
  }
  std::wstring open_params =
      safe_open_path.empty() ? std::wstring() : (L"\"" + safe_open_path + L"\"");

  std::wstring wtarget = Utf8ToWide(target);
  if (wtarget.empty()) {
    if (out_error_code) *out_error_code = "invalid_args";
    if (out_error_msg) *out_error_msg = "Invalid target";
    return false;
  }

  std::wstring expanded_wtarget = ExpandWindowsEnvVars(wtarget);
  if (!expanded_wtarget.empty() &&
      IsHardDeniedWindowsAppStem(WideToUtf8(expanded_wtarget))) {
    if (out_error_code) *out_error_code = "denylisted_target_forbidden";
    if (out_error_msg) *out_error_msg = "Target application is forbidden by policy";
    return false;
  }

  const bool is_lnk_target = EndsWithLnkExtension(target);
  if (kind == "lnk" || is_lnk_target) {
    std::string lnk_target;
    std::string lnk_raw_target;
    if (ResolveShortcutTargetUtf8(wtarget, &lnk_target, &lnk_raw_target) &&
        (IsHardDeniedWindowsAppStem(lnk_target) ||
         (!lnk_raw_target.empty() &&
          IsHardDeniedWindowsAppStem(lnk_raw_target)))) {
      if (out_error_code) *out_error_code = "denylisted_target_forbidden";
      if (out_error_msg) *out_error_msg = "Shortcut target is forbidden by policy";
      return false;
    }
    if (kind == "exe" && is_lnk_target) {
      if (out_error_code) *out_error_code = "invalid_args";
      if (out_error_msg) *out_error_msg = "Shortcut (.lnk) targets require kind=lnk";
      return false;
    }
  }

  if (out_already_running && kind != "aumid") {
    *out_already_running = IsWindowsTargetAlreadyRunning(target);
  }

  if (kind == "aumid") {
    IApplicationActivationManager* mgr = nullptr;
    HRESULT hr = CoCreateInstance(
        CLSID_ApplicationActivationManager, nullptr, CLSCTX_LOCAL_SERVER,
        IID_PPV_ARGS(&mgr));
    if (SUCCEEDED(hr) && mgr != nullptr) {
      DWORD pid = 0;
      hr = mgr->ActivateApplication(
          wtarget.c_str(),
          open_params.empty() ? nullptr : open_params.c_str(), AO_NONE, &pid);
      mgr->Release();
      if (SUCCEEDED(hr)) return true;
    }
    if (!open_params.empty()) {
      if (out_error_code) *out_error_code = "os_error";
      if (out_error_msg) {
        *out_error_msg =
            "ActivateApplication failed; cannot forward openPath via shell:AppsFolder";
      }
      return false;
    }
    std::wstring explorer_arg = L"shell:AppsFolder\\" + wtarget;
    SHELLEXECUTEINFOW sei = {sizeof(sei)};
    sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    sei.lpVerb = L"open";
    sei.lpFile = explorer_arg.c_str();
    sei.nShow = SW_SHOWNORMAL;
    if (ShellExecuteExW(&sei) == TRUE) return true;
    if (out_error_code) *out_error_code = "os_error";
    if (out_error_msg) *out_error_msg = "ActivateApplication / ShellExecuteExW failed";
    return false;
  }

  SHELLEXECUTEINFOW sei = {sizeof(sei)};
  sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  sei.lpVerb = L"open";
  sei.lpFile = wtarget.c_str();
  sei.lpParameters = open_params.empty() ? nullptr : open_params.c_str();
  sei.nShow = SW_SHOWNORMAL;
  if (ShellExecuteExW(&sei) == TRUE) {
    return true;
  }

  std::wstring discovered;
  if (!is_workflow && DiscoverInstalledWindowsAppTarget(target, &discovered) &&
      !IsHardDeniedWindowsAppStem(WideToUtf8(discovered))) {
    std::string disc_lnk_target;
    std::string disc_lnk_raw;
    if (ResolveShortcutTargetUtf8(discovered, &disc_lnk_target, &disc_lnk_raw) &&
        (IsHardDeniedWindowsAppStem(disc_lnk_target) ||
         (!disc_lnk_raw.empty() && IsHardDeniedWindowsAppStem(disc_lnk_raw)))) {
      if (out_error_code) *out_error_code = "denylisted_target_forbidden";
      if (out_error_msg) *out_error_msg = "Discovered shortcut target is forbidden by policy";
      return false;
    }
    if (out_already_running && !*out_already_running) {
      *out_already_running =
          IsWindowsTargetAlreadyRunning(WideToUtf8(discovered));
    }
    SHELLEXECUTEINFOW retry_sei = {sizeof(retry_sei)};
    retry_sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    retry_sei.lpVerb = L"open";
    retry_sei.lpFile = discovered.c_str();
    retry_sei.lpParameters = open_params.empty() ? nullptr : open_params.c_str();
    retry_sei.nShow = SW_SHOWNORMAL;
    if (ShellExecuteExW(&retry_sei) == TRUE) return true;
  }
  if (out_error_code) *out_error_code = "os_error";
  if (out_error_msg) *out_error_msg = "ShellExecuteExW failed";
  return false;
}

inline bool IsValidPublicHttpsUrlWindows(const std::string& raw_url) {
  if (raw_url.empty() || raw_url.size() > 2048) return false;
  for (unsigned char ch : raw_url) {
    if (ch < 0x20 || ch == 0x7F) return false;
  }
  size_t start = 0;
  size_t end = raw_url.size();
  while (start < end && raw_url[start] == ' ') ++start;
  while (end > start && raw_url[end - 1] == ' ') --end;
  if (end <= start) return false;
  std::string url = raw_url.substr(start, end - start);
  if (url.size() < 9 || url.size() > 2048) return false;
  for (unsigned char ch : url) {
    if (ch <= 0x20 || ch == 0x7F) return false;
  }
  if (ToLowerAscii(url.substr(0, 8)) != "https://") return false;
  size_t auth_start = 8;
  size_t auth_end = url.find_first_of("/?#", auth_start);
  std::string authority = auth_end == std::string::npos
                              ? url.substr(auth_start)
                              : url.substr(auth_start, auth_end - auth_start);
  if (authority.empty() ||
      authority.find('@') != std::string::npos ||
      authority.find('[') != std::string::npos ||
      authority.find(']') != std::string::npos ||
      authority.find('\\') != std::string::npos) {
    return false;
  }
  size_t colon = authority.find(':');
  std::string host = colon == std::string::npos ? authority
                                               : authority.substr(0, colon);
  if (colon != std::string::npos) {
    if (authority.find(':', colon + 1) != std::string::npos) return false;
    std::string port_str = authority.substr(colon + 1);
    if (port_str.empty() || port_str.size() > 5) return false;
    int port = 0;
    for (unsigned char ch : port_str) {
      if (!std::isdigit(ch)) return false;
      port = port * 10 + (ch - '0');
    }
    if (port <= 0 || port > 65535) return false;
  }
  host = ToLowerAscii(host);
  if (host.empty() || host.back() == '.') return false;

  auto ends_with = [&](const std::string& suffix) -> bool {
    return host.size() >= suffix.size() &&
           host.compare(host.size() - suffix.size(), suffix.size(), suffix) == 0;
  };
  if (host == "localhost" || host == "localhost.localdomain" ||
      host == "home.arpa" || ends_with(".localhost") ||
      ends_with(".local") || ends_with(".internal") ||
      ends_with(".localdomain") || ends_with(".lan") ||
      ends_with(".home.arpa")) {
    return false;
  }

  std::vector<std::string> labels;
  size_t pos = 0;
  while (pos <= host.size()) {
    size_t dot = host.find('.', pos);
    std::string lbl =
        dot == std::string::npos ? host.substr(pos) : host.substr(pos, dot - pos);
    if (lbl.empty()) return false;
    labels.push_back(lbl);
    if (dot == std::string::npos) break;
    pos = dot + 1;
  }
  if (labels.size() < 2) return false;

  auto is_dec_or_hex = [](const std::string& lbl) -> bool {
    if (lbl.empty()) return false;
    if (lbl.size() > 2 && lbl[0] == '0' && lbl[1] == 'x') {
      for (size_t i = 2; i < lbl.size(); ++i) {
        if (!std::isxdigit(static_cast<unsigned char>(lbl[i]))) return false;
      }
      return true;
    }
    for (unsigned char ch : lbl) {
      if (!std::isdigit(ch)) return false;
    }
    return true;
  };
  if (is_dec_or_hex(labels.back())) return false;
  for (const auto& lbl : labels) {
    if (lbl.rfind("0x", 0) == 0 && is_dec_or_hex(lbl)) return false;
  }
  return true;
}

inline bool OpenHttpsUrl(const std::string& url) {
  if (!IsValidPublicHttpsUrlWindows(url)) {
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

struct BrowserWindowCandidate {
  HWND hwnd = nullptr;
  std::string browser;
};

inline std::string ClassifyBrowserProcessStem(HWND hwnd) {
  std::string stem = ToLowerAscii(QueryProcessBaseNameForHwnd(hwnd));
  if (stem == "msedge") return "edge";
  if (stem == "chrome") return "chrome";
  return std::string();
}

inline bool IsNonEmptyVisibleBrowserWindow(HWND hwnd) {
  if (hwnd == nullptr || !IsWindowVisible(hwnd)) return false;
  RECT rc = {};
  if (!GetWindowRect(hwnd, &rc)) return false;
  return (rc.right - rc.left) > 0 && (rc.bottom - rc.top) > 0;
}

inline BOOL CALLBACK EnumChromiumBrowserWindowsCb(HWND hwnd, LPARAM lparam) {
  if (!IsNonEmptyVisibleBrowserWindow(hwnd)) return TRUE;
  wchar_t class_name[128] = {};
  if (GetClassNameW(hwnd, class_name, 128) == 0) return TRUE;
  if (wcscmp(class_name, L"Chrome_WidgetWin_1") != 0) return TRUE;
  std::string browser = ClassifyBrowserProcessStem(hwnd);
  if (browser.empty()) return TRUE;
  auto* out = reinterpret_cast<std::vector<BrowserWindowCandidate>*>(lparam);
  out->push_back(BrowserWindowCandidate{hwnd, browser});
  return TRUE;
}

inline bool IsLikelyAddressBarEdit(IUIAutomationElement* elem) {
  auto contains_hint = [](BSTR b) -> bool {
    if (b == nullptr) return false;
    std::string s = ToLowerAscii(WideToUtf8(std::wstring(b, SysStringLen(b))));
    return s.find("address") != std::string::npos ||
           s.find("omnibox") != std::string::npos ||
           s.find("url") != std::string::npos ||
           s.find("search or enter") != std::string::npos;
  };
  bool matched = false;
  BSTR name_bstr = nullptr;
  if (SUCCEEDED(elem->get_CurrentName(&name_bstr)) && name_bstr != nullptr) {
    matched = contains_hint(name_bstr);
    SysFreeString(name_bstr);
  }
  if (!matched) {
    BSTR aid_bstr = nullptr;
    if (SUCCEEDED(elem->get_CurrentAutomationId(&aid_bstr)) &&
        aid_bstr != nullptr) {
      matched = contains_hint(aid_bstr);
      SysFreeString(aid_bstr);
    }
  }
  if (!matched) {
    BSTR acc_bstr = nullptr;
    if (SUCCEEDED(elem->get_CurrentAcceleratorKey(&acc_bstr)) &&
        acc_bstr != nullptr) {
      std::string acc =
          ToLowerAscii(WideToUtf8(std::wstring(acc_bstr, SysStringLen(acc_bstr))));
      SysFreeString(acc_bstr);
      if (acc.find("ctrl+l") != std::string::npos ||
          acc.find("alt+d") != std::string::npos) {
        matched = true;
      }
    }
  }
  return matched;
}

inline bool InspectEditHierarchy(IUIAutomation* uia,
                                 IUIAutomationTreeWalker* walker,
                                 IUIAutomationElement* root,
                                 IUIAutomationElement* elem,
                                 bool* out_in_document,
                                 bool* out_in_toolbar) {
  *out_in_document = false;
  *out_in_toolbar = false;
  if (uia == nullptr || walker == nullptr || root == nullptr || elem == nullptr) {
    return false;
  }
  IUIAutomationElement* current = elem;
  current->AddRef();
  bool reached_boundary = false;
  for (int depth = 0; depth < 128; ++depth) {
    IUIAutomationElement* parent = nullptr;
    HRESULT hr = walker->GetParentElement(current, &parent);
    current->Release();
    current = nullptr;
    if (FAILED(hr) || parent == nullptr) {
      break;
    }
    CONTROLTYPEID ctrl_type = 0;
    if (SUCCEEDED(parent->get_CurrentControlType(&ctrl_type))) {
      if (ctrl_type == UIA_DocumentControlTypeId) {
        *out_in_document = true;
        reached_boundary = true;
        parent->Release();
        break;
      }
      if (ctrl_type == UIA_ToolBarControlTypeId) {
        *out_in_toolbar = true;
      }
    }
    BOOL same = FALSE;
    if (SUCCEEDED(uia->CompareElements(parent, root, &same)) && same) {
      reached_boundary = true;
      parent->Release();
      break;
    }
    current = parent;
  }
  if (current != nullptr) {
    current->Release();
    current = nullptr;
  }
  return reached_boundary;
}

inline bool QueryBrowserCurrentUrlUia(const std::string& requested_browser,
                                      std::string* out_url,
                                      std::string* out_browser,
                                      std::string* out_error_code = nullptr,
                                      std::string* out_error_msg = nullptr) {
  std::string req = ToLowerAscii(requested_browser);
  if (req.empty()) req = "auto";
  if (req != "auto" && req != "edge" && req != "chrome") {
    if (out_error_code) *out_error_code = "unsupported_browser";
    if (out_error_msg) {
      *out_error_msg =
          req == "safari"
              ? "Safari is not supported on Windows"
              : "Unsupported browser requested";
    }
    return false;
  }

  std::vector<BrowserWindowCandidate> candidates;
  HWND fg = GetForegroundWindow();
  if (IsNonEmptyVisibleBrowserWindow(fg)) {
    wchar_t class_name[128] = {};
    if (GetClassNameW(fg, class_name, 128) > 0 &&
        wcscmp(class_name, L"Chrome_WidgetWin_1") == 0) {
      std::string fg_browser = ClassifyBrowserProcessStem(fg);
      if (!fg_browser.empty()) {
        candidates.push_back(BrowserWindowCandidate{fg, fg_browser});
      }
    }
  }

  std::vector<BrowserWindowCandidate> enumerated;
  EnumWindows(EnumChromiumBrowserWindowsCb,
              reinterpret_cast<LPARAM>(&enumerated));
  for (const auto& c : enumerated) {
    if (c.hwnd != fg) {
      candidates.push_back(c);
    }
  }

  HWND target_hwnd = nullptr;
  std::string detected_browser;
  if (req != "auto") {
    for (const auto& c : candidates) {
      if (c.browser == req) {
        target_hwnd = c.hwnd;
        detected_browser = c.browser;
        break;
      }
    }
    if (target_hwnd == nullptr) {
      if (out_error_code) *out_error_code = "browser_not_running";
      if (out_error_msg) *out_error_msg = "Requested browser is not running";
      return false;
    }
  } else {
    if (!candidates.empty() && candidates.front().hwnd == fg) {
      target_hwnd = candidates.front().hwnd;
      detected_browser = candidates.front().browser;
    } else {
      bool has_edge = false;
      bool has_chrome = false;
      for (const auto& c : candidates) {
        if (c.browser == "edge") has_edge = true;
        if (c.browser == "chrome") has_chrome = true;
      }
      if (!has_edge && !has_chrome) {
        if (out_error_code) *out_error_code = "browser_not_running";
        if (out_error_msg) *out_error_msg = "No supported browser (Edge/Chrome) is running";
        return false;
      }
      if (has_edge && has_chrome) {
        if (out_error_code) *out_error_code = "browser_ambiguous";
        if (out_error_msg) {
          *out_error_msg =
              "Multiple browsers running (edge, chrome); specify browser or focus one";
        }
        return false;
      }
      target_hwnd = candidates.front().hwnd;
      detected_browser = candidates.front().browser;
    }
  }

  IUIAutomation* uia = nullptr;
  HRESULT hr = CoCreateInstance(__uuidof(CUIAutomation), nullptr,
                                CLSCTX_INPROC_SERVER,
                                __uuidof(IUIAutomation),
                                reinterpret_cast<void**>(&uia));
  if (FAILED(hr) || uia == nullptr) {
    if (out_error_code) *out_error_code = "os_error";
    if (out_error_msg) *out_error_msg = "Failed to initialize UIAutomation";
    return false;
  }

  IUIAutomationElement* root = nullptr;
  hr = uia->ElementFromHandle(target_hwnd, &root);
  if (FAILED(hr) || root == nullptr) {
    uia->Release();
    if (out_error_code) *out_error_code = "os_error";
    if (out_error_msg) *out_error_msg = "Failed to bind UIA root to browser window";
    return false;
  }

  IUIAutomationTreeWalker* walker = nullptr;
  hr = uia->get_ControlViewWalker(&walker);
  if (FAILED(hr) || walker == nullptr) {
    root->Release();
    uia->Release();
    if (out_error_code) *out_error_code = "os_error";
    if (out_error_msg) *out_error_msg = "Failed to acquire UIA ControlViewWalker";
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
    walker->Release();
    root->Release();
    uia->Release();
    if (out_error_code) *out_error_code = "os_error";
    if (out_error_msg) *out_error_msg = "Failed to create UIA edit condition";
    return false;
  }

  IUIAutomationElementArray* edits = nullptr;
  hr = root->FindAll(TreeScope_Descendants, edit_cond, &edits);
  edit_cond->Release();
  if (FAILED(hr) || edits == nullptr) {
    walker->Release();
    root->Release();
    uia->Release();
    if (out_error_code) *out_error_code = "url_invalid";
    if (out_error_msg) *out_error_msg = "No active https:// browser tab found via UIA";
    return false;
  }

  int length = 0;
  edits->get_Length(&length);
  bool found = false;
  std::string toolbar_url;
  std::string hinted_url;
  for (int i = 0; i < length; ++i) {
    IUIAutomationElement* elem = nullptr;
    if (FAILED(edits->GetElement(i, &elem)) || elem == nullptr) continue;
    BOOL is_pwd = FALSE;
    elem->get_CurrentIsPassword(&is_pwd);
    bool in_document = false;
    bool in_toolbar = false;
    if (!is_pwd &&
        InspectEditHierarchy(uia, walker, root, elem, &in_document,
                             &in_toolbar) &&
        !in_document) {
      const bool prioritized = IsLikelyAddressBarEdit(elem);
      if (in_toolbar || prioritized) {
        IUIAutomationValuePattern* val_pat = nullptr;
        if (SUCCEEDED(elem->GetCurrentPatternAs(
                UIA_ValuePatternId, __uuidof(IUIAutomationValuePattern),
                reinterpret_cast<void**>(&val_pat))) &&
            val_pat != nullptr) {
          BSTR bval = nullptr;
          if (SUCCEEDED(val_pat->get_CurrentValue(&bval)) && bval != nullptr) {
            std::string candidate =
                WideToUtf8(std::wstring(bval, SysStringLen(bval)));
            SysFreeString(bval);
            if (IsValidPublicHttpsUrlWindows(candidate)) {
              size_t s = 0;
              size_t e = candidate.size();
              while (s < e && candidate[s] == ' ') ++s;
              while (e > s && candidate[e - 1] == ' ') --e;
              std::string trimmed_url = candidate.substr(s, e - s);
              if (in_toolbar && prioritized) {
                *out_url = trimmed_url;
                *out_browser = detected_browser;
                found = true;
              } else if (in_toolbar && toolbar_url.empty()) {
                toolbar_url = trimmed_url;
              } else if (prioritized && hinted_url.empty()) {
                hinted_url = trimmed_url;
              }
            }
          }
          val_pat->Release();
        }
      }
    }
    elem->Release();
    if (found) break;
  }

  if (!found) {
    if (!toolbar_url.empty()) {
      *out_url = toolbar_url;
      *out_browser = detected_browser;
      found = true;
    } else if (!hinted_url.empty()) {
      *out_url = hinted_url;
      *out_browser = detected_browser;
      found = true;
    }
  }

  edits->Release();
  walker->Release();
  root->Release();
  uia->Release();
  if (!found) {
    if (out_error_code) *out_error_code = "url_invalid";
    if (out_error_msg) *out_error_msg = "No active https:// browser tab found via UIA";
  }
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
