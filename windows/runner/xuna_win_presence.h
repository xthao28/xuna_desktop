#ifndef RUNNER_XUNA_WIN_PRESENCE_H_
#define RUNNER_XUNA_WIN_PRESENCE_H_

#include "xuna_win_common.h"

#include <wtsapi32.h>

#include <chrono>

namespace xuna_win {

inline bool IsElevatedHwnd(HWND hwnd) {
  if (hwnd == nullptr) return false;
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0) return false;
  HANDLE h_proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (h_proc == nullptr) return false;
  bool elevated = false;
  HANDLE h_tok = nullptr;
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
  return elevated;
}

inline std::string NormalizePresenceAppId(const std::string& raw) {
  std::string lower = ToLowerAscii(raw);
  // Trim leading/trailing ASCII whitespace.
  size_t first = 0;
  while (first < lower.size() &&
         std::isspace(static_cast<unsigned char>(lower[first]))) {
    ++first;
  }
  size_t last = lower.size();
  while (last > first &&
         std::isspace(static_cast<unsigned char>(lower[last - 1]))) {
    --last;
  }
  lower = lower.substr(first, last - first);
  for (const char* suffix : {".app", ".exe", ".lnk", ".cmd"}) {
    const size_t slen = std::strlen(suffix);
    if (lower.size() > slen &&
        lower.compare(lower.size() - slen, slen, suffix) == 0) {
      lower.erase(lower.size() - slen);
      break;
    }
  }

  std::string out;
  out.reserve(lower.size());
  bool prev_underscore = false;
  for (unsigned char c : lower) {
    const bool valid =
        (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' ||
        c == '-' || c == '_';
    if (valid && c != '_') {
      out.push_back(static_cast<char>(c));
      prev_underscore = false;
    } else if (!prev_underscore && !out.empty()) {
      out.push_back('_');
      prev_underscore = true;
    }
  }
  while (!out.empty() && out.back() == '_') {
    out.pop_back();
  }
  if (out.size() > 64) {
    out.resize(64);
    while (!out.empty() && out.back() == '_') {
      out.pop_back();
    }
  }
  return out;
}

inline bool IsHardDeniedPresenceAppId(const std::string& normalized_id) {
  if (normalized_id.empty()) return true;
  static const char* kDeniedIds[] = {
      "cmd",          "powershell",      "pwsh",         "wt",
      "windowsterminal", "bash",         "zsh",          "wsl",
      "conhost",      "alacritty",       "kitty",        "wezterm",
      "wezterm-gui",  "ghostty",         "hyper",        "1password",
      "bitwarden",    "keepass",         "keepassxc",    "lastpass",
      "dashlane",     "systemsettings",  "system_settings", "control",
      "regedit",      "mmc",             "taskmgr",         "secpol",
      "gpedit",       "consent",         "credentialuibroker",
  };
  for (const char* denied : kDeniedIds) {
    if (normalized_id == denied) {
      return true;
    }
  }
  return false;
}

inline bool QueryWindowsScreenLocked(bool* out_locked, std::string* error_msg) {
  LPWSTR buffer = nullptr;
  DWORD bytes = 0;
  if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE,
                                  WTS_CURRENT_SESSION, WTSSessionInfoEx,
                                  &buffer, &bytes) &&
      buffer != nullptr && bytes >= sizeof(WTSINFOEXW)) {
    const auto* info = reinterpret_cast<const WTSINFOEXW*>(buffer);
    const DWORD level = info->Level;
    const LONG flags =
        (level == 1) ? info->Data.WTSInfoExLevel1.SessionFlags : 0;
    WTSFreeMemory(buffer);
    if (level == 1) {
      if (flags == WTS_SESSIONSTATE_LOCK) {
        *out_locked = true;
        return true;
      }
      if (flags == WTS_SESSIONSTATE_UNLOCK) {
        *out_locked = false;
        return true;
      }
    }
  } else if (buffer != nullptr) {
    WTSFreeMemory(buffer);
  }

  HDESK desk = OpenInputDesktop(0, FALSE, DESKTOP_SWITCHDESKTOP);
  if (desk != nullptr) {
    CloseDesktop(desk);
    *out_locked = false;
    return true;
  }
  if (GetLastError() == ERROR_ACCESS_DENIED) {
    *out_locked = true;
    return true;
  }
  *error_msg = "Unable to query Windows session lock state";
  return false;
}

inline bool QueryWindowsMediaPlaying(bool* out_playing,
                                     std::string* error_msg,
                                     std::string* diag_note = nullptr) {
#if XUNA_HAS_CPPWINRT_GSMTC
  try {
    using winrt::Windows::Foundation::AsyncStatus;
    using winrt::Windows::Media::Control::
        GlobalSystemMediaTransportControlsSessionManager;
    using winrt::Windows::Media::Control::
        GlobalSystemMediaTransportControlsSessionPlaybackStatus;

    auto op = GlobalSystemMediaTransportControlsSessionManager::RequestAsync();
    if (op.wait_for(std::chrono::milliseconds(30)) != AsyncStatus::Completed) {
      *out_playing = false;
      if (diag_note != nullptr) {
        *diag_note = "WinRT SMTC query timed out; degraded mediaPlaying=false";
      }
      return true;
    }
    auto manager = op.GetResults();
    if (manager == nullptr) {
      *out_playing = false;
      return true;
    }
    bool playing = false;
    auto sessions = manager.GetSessions();
    if (sessions != nullptr) {
      for (auto const& session : sessions) {
        if (session == nullptr) continue;
        auto info = session.GetPlaybackInfo();
        if (info != nullptr &&
            info.PlaybackStatus() ==
                GlobalSystemMediaTransportControlsSessionPlaybackStatus::
                    Playing) {
          playing = true;
          break;
        }
      }
    } else if (auto current = manager.GetCurrentSession()) {
      auto info = current.GetPlaybackInfo();
      if (info != nullptr &&
          info.PlaybackStatus() ==
              GlobalSystemMediaTransportControlsSessionPlaybackStatus::
                  Playing) {
        playing = true;
      }
    }
    *out_playing = playing;
    return true;
  } catch (...) {
    *error_msg = "WinRT SMTC query failed";
    return false;
  }
#else
  *out_playing = false;
  if (diag_note != nullptr) {
    *diag_note = "WinRT SMTC headers unavailable; degraded mediaPlaying=false";
  }
  return true;
#endif
}

inline bool QueryWindowsPresence(flutter::EncodableMap* out,
                                 std::string* error_msg) {
  LASTINPUTINFO lii = {};
  lii.cbSize = sizeof(LASTINPUTINFO);
  if (!GetLastInputInfo(&lii)) {
    *error_msg = "GetLastInputInfo failed";
    return false;
  }
  const DWORD now32 = static_cast<DWORD>(GetTickCount64() & 0xFFFFFFFFULL);
  const DWORD elapsed_ms = now32 - lii.dwTime;
  const int64_t idle_seconds = static_cast<int64_t>(elapsed_ms / 1000U);

  bool screen_locked = false;
  if (!QueryWindowsScreenLocked(&screen_locked, error_msg)) {
    return false;
  }

  bool media_playing = false;
  std::string media_diag;
  if (!QueryWindowsMediaPlaying(&media_playing, error_msg, &media_diag)) {
    return false;
  }
  if (!media_diag.empty()) {
    OutputDebugStringA(media_diag.c_str());
  }

  SYSTEM_POWER_STATUS sps = {};
  if (!GetSystemPowerStatus(&sps)) {
    *error_msg = "GetSystemPowerStatus failed";
    return false;
  }

  (*out)[flutter::EncodableValue("idleSeconds")] =
      flutter::EncodableValue(idle_seconds);
  (*out)[flutter::EncodableValue("screenLocked")] =
      flutter::EncodableValue(screen_locked);
  (*out)[flutter::EncodableValue("mediaPlaying")] =
      flutter::EncodableValue(media_playing);

  // Omit batteryPercent and isCharging on desktop PCs without an internal
  // battery or when the battery percentage is unknown (255).
  if ((sps.BatteryFlag & 128) == 0 && sps.BatteryLifePercent != 255) {
    const int32_t pct =
        std::min<int32_t>(static_cast<int32_t>(sps.BatteryLifePercent), 100);
    const bool charging =
        (sps.ACLineStatus == 1) || ((sps.BatteryFlag & 8) != 0);
    (*out)[flutter::EncodableValue("batteryPercent")] =
        flutter::EncodableValue(pct);
    (*out)[flutter::EncodableValue("isCharging")] =
        flutter::EncodableValue(charging);
  }

  HWND fg_hwnd = GetForegroundWindow();
  if (fg_hwnd != nullptr && !IsElevatedHwnd(fg_hwnd)) {
    const std::string raw_stem = QueryProcessBaseNameForHwnd(fg_hwnd);
    const std::string norm_id = NormalizePresenceAppId(raw_stem);
    if (!norm_id.empty() && !IsHardDeniedPresenceAppId(norm_id)) {
      (*out)[flutter::EncodableValue("foregroundAppId")] =
          flutter::EncodableValue(norm_id);
    }
  }

  return true;
}

}  // namespace xuna_win

#endif  // RUNNER_XUNA_WIN_PRESENCE_H_
