#include "xuna_host_plugin.h"

#include <windows.h>
#include <bcrypt.h>
#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <ncrypt.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <wincrypt.h>

#if __has_include(<winrt/Windows.Foundation.h>) && \
    __has_include(<winrt/Windows.Foundation.Collections.h>) && \
    __has_include(<winrt/Windows.Media.Control.h>)
#define XUNA_HAS_CPPWINRT_GSMTC 1
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Control.h>
#else
#define XUNA_HAS_CPPWINRT_GSMTC 0
#endif

#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr wchar_t kXunaKeyName[] = L"XunaHostIdentityP256_v1";

using NTSTATUS_T = LONG;
using RtlGetVersionFn = NTSTATUS_T(WINAPI*)(PRTL_OSVERSIONINFOW);

std::wstring Utf8ToWide(const std::string& str) {
  if (str.empty()) return std::wstring();
  int size_needed = MultiByteToWideChar(
      CP_UTF8, 0, str.data(), static_cast<int>(str.size()), nullptr, 0);
  if (size_needed <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(size_needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, str.data(), static_cast<int>(str.size()),
                      out.data(), size_needed);
  return out;
}

std::string WideToUtf8(const std::wstring& wstr) {
  if (wstr.empty()) return std::string();
  int size_needed =
      WideCharToMultiByte(CP_UTF8, 0, wstr.data(),
                          static_cast<int>(wstr.size()), nullptr, 0,
                          nullptr, nullptr);
  if (size_needed <= 0) return std::string();
  std::string out(static_cast<size_t>(size_needed), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()),
                      out.data(), size_needed, nullptr, nullptr);
  return out;
}

std::string Base64Encode(const std::vector<uint8_t>& bytes) {
  if (bytes.empty()) return std::string();
  DWORD out_len = 0;
  if (!CryptBinaryToStringA(bytes.data(), static_cast<DWORD>(bytes.size()),
                            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr,
                            &out_len) ||
      out_len == 0) {
    return std::string();
  }
  std::string out(static_cast<size_t>(out_len), '\0');
  if (!CryptBinaryToStringA(bytes.data(), static_cast<DWORD>(bytes.size()),
                            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                            out.data(), &out_len)) {
    return std::string();
  }
  while (!out.empty() && (out.back() == '\0' || out.back() == '\r' ||
                          out.back() == '\n')) {
    out.pop_back();
  }
  return out;
}

bool Base64Decode(const std::string& input, std::vector<uint8_t>* out) {
  if (input.empty()) {
    out->clear();
    return true;
  }
  DWORD bin_len = 0;
  if (!CryptStringToBinaryA(input.data(), static_cast<DWORD>(input.size()),
                            CRYPT_STRING_BASE64_ANY, nullptr, &bin_len, nullptr,
                            nullptr)) {
    return false;
  }
  out->resize(static_cast<size_t>(bin_len));
  if (!CryptStringToBinaryA(input.data(), static_cast<DWORD>(input.size()),
                            CRYPT_STRING_BASE64_ANY, out->data(), &bin_len,
                            nullptr, nullptr)) {
    return false;
  }
  out->resize(static_cast<size_t>(bin_len));
  return true;
}

std::string ToLowerAscii(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return s;
}

std::string TruncateUtf8(const std::string& s, size_t max_chars) {
  if (s.size() <= max_chars) return s;
  return s.substr(0, max_chars);
}

// Opens or creates a non-exportable P-256 key in CNG (preferring TPM
// MS_PLATFORM_CRYPTO_PROVIDER, falling back to MS_KEY_STORAGE_PROVIDER).
bool OpenOrCreateCngP256Key(NCRYPT_PROV_HANDLE* out_prov,
                            NCRYPT_KEY_HANDLE* out_key) {
  *out_prov = 0;
  *out_key = 0;

  const wchar_t* providers[] = {MS_PLATFORM_CRYPTO_PROVIDER,
                                MS_KEY_STORAGE_PROVIDER};

  for (const wchar_t* prov_name : providers) {
    NCRYPT_PROV_HANDLE prov = 0;
    if (NCryptOpenStorageProvider(&prov, prov_name, 0) != ERROR_SUCCESS) {
      continue;
    }

    NCRYPT_KEY_HANDLE key = 0;
    SECURITY_STATUS status =
        NCryptOpenKey(prov, &key, kXunaKeyName, 0, NCRYPT_SILENT_FLAG);
    if (status == ERROR_SUCCESS) {
      *out_prov = prov;
      *out_key = key;
      return true;
    }

    status = NCryptCreatePersistedKey(prov, &key, NCRYPT_ECDSA_P256_ALGORITHM,
                                      kXunaKeyName, 0, 0);
    if (status != ERROR_SUCCESS) {
      NCryptFreeObject(prov);
      continue;
    }

    DWORD export_policy = 0;  // Non-exportable private key.
    NCryptSetProperty(key, NCRYPT_EXPORT_POLICY_PROPERTY,
                      reinterpret_cast<PBYTE>(&export_policy),
                      sizeof(export_policy), NCRYPT_PERSIST_FLAG);

    status = NCryptFinalizeKey(key, NCRYPT_SILENT_FLAG);
    if (status == ERROR_SUCCESS) {
      *out_prov = prov;
      *out_key = key;
      return true;
    }

    NCryptFreeObject(key);
    NCryptFreeObject(prov);
  }
  return false;
}

bool ExportUncompressedPublicKey65(NCRYPT_KEY_HANDLE key,
                                   std::vector<uint8_t>* out_pub65) {
  DWORD blob_size = 0;
  if (NCryptExportKey(key, 0, BCRYPT_ECCPUBLIC_BLOB, nullptr, nullptr, 0,
                      &blob_size, 0) != ERROR_SUCCESS ||
      blob_size < sizeof(BCRYPT_ECCKEY_BLOB) + 64) {
    return false;
  }
  std::vector<uint8_t> blob(static_cast<size_t>(blob_size));
  if (NCryptExportKey(key, 0, BCRYPT_ECCPUBLIC_BLOB, nullptr, blob.data(),
                      blob_size, &blob_size, 0) != ERROR_SUCCESS) {
    return false;
  }
  const auto* header = reinterpret_cast<const BCRYPT_ECCKEY_BLOB*>(blob.data());
  if (header->cbKey != 32 ||
      blob.size() < sizeof(BCRYPT_ECCKEY_BLOB) + 64) {
    return false;
  }
  out_pub65->resize(65);
  (*out_pub65)[0] = 0x04;
  std::copy(blob.begin() + sizeof(BCRYPT_ECCKEY_BLOB),
            blob.begin() + sizeof(BCRYPT_ECCKEY_BLOB) + 64,
            out_pub65->begin() + 1);
  return true;
}

bool ComputeSha256(const std::vector<uint8_t>& message,
                   std::vector<uint8_t>* out_digest32) {
  BCRYPT_ALG_HANDLE alg = nullptr;
  if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) !=
      0) {
    return false;
  }
  out_digest32->resize(32);
  NTSTATUS status = BCryptHash(
      alg, nullptr, 0, const_cast<PUCHAR>(message.data()),
      static_cast<ULONG>(message.size()), out_digest32->data(), 32);
  BCryptCloseAlgorithmProvider(alg, 0);
  return status == 0;
}

bool SignMessageCngP256(const std::vector<uint8_t>& message,
                        std::vector<uint8_t>* out_sig64) {
  std::vector<uint8_t> digest;
  if (!ComputeSha256(message, &digest)) {
    return false;
  }
  NCRYPT_PROV_HANDLE prov = 0;
  NCRYPT_KEY_HANDLE key = 0;
  if (!OpenOrCreateCngP256Key(&prov, &key)) {
    return false;
  }

  DWORD sig_len = 0;
  SECURITY_STATUS status = NCryptSignHash(
      key, nullptr, digest.data(), static_cast<DWORD>(digest.size()), nullptr,
      0, &sig_len, NCRYPT_SILENT_FLAG);
  if (status != ERROR_SUCCESS || sig_len != 64) {
    NCryptFreeObject(key);
    NCryptFreeObject(prov);
    return false;
  }

  out_sig64->resize(64);
  status = NCryptSignHash(key, nullptr, digest.data(),
                          static_cast<DWORD>(digest.size()), out_sig64->data(),
                          64, &sig_len, NCRYPT_SILENT_FLAG);
  NCryptFreeObject(key);
  NCryptFreeObject(prov);
  return status == ERROR_SUCCESS && sig_len == 64;
}

void SendMediaVirtualKey(WORD vk) {
  INPUT inputs[2] = {};
  inputs[0].type = INPUT_KEYBOARD;
  inputs[0].ki.wVk = vk;
  inputs[1].type = INPUT_KEYBOARD;
  inputs[1].ki.wVk = vk;
  inputs[1].ki.dwFlags = KEYEVENTF_KEYUP;
  SendInput(2, inputs, sizeof(INPUT));
}

bool HandleMediaCommand(const std::string& cmd, std::string* out_state) {
  *out_state = "unknown";
#if XUNA_HAS_CPPWINRT_GSMTC
  try {
    using winrt::Windows::Media::Control::
        GlobalSystemMediaTransportControlsSessionManager;
    using winrt::Windows::Media::Control::
        GlobalSystemMediaTransportControlsSessionPlaybackStatus;

    auto manager =
        GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
    auto session = manager ? manager.GetCurrentSession() : nullptr;
    if (session != nullptr) {
      bool ok = false;
      if (cmd == "play_pause") {
        auto info = session.GetPlaybackInfo();
        auto status = info.PlaybackStatus();
        ok = session.TryTogglePlayPauseAsync().get();
        if (ok) {
          *out_state =
              (status == GlobalSystemMediaTransportControlsSessionPlaybackStatus::
                             Playing)
                  ? "paused"
                  : "playing";
        }
      } else if (cmd == "next") {
        ok = session.TrySkipNextAsync().get();
        *out_state = "playing";
      } else if (cmd == "previous") {
        ok = session.TrySkipPreviousAsync().get();
        *out_state = "playing";
      }
      if (ok) {
        return true;
      }
    }
  } catch (...) {
    // Fall back to virtual media keys below.
  }
#endif

  if (cmd == "play_pause") {
    SendMediaVirtualKey(VK_MEDIA_PLAY_PAUSE);
    *out_state = "unknown";
    return true;
  }
  if (cmd == "next") {
    SendMediaVirtualKey(VK_MEDIA_NEXT_TRACK);
    *out_state = "unknown";
    return true;
  }
  if (cmd == "previous") {
    SendMediaVirtualKey(VK_MEDIA_PREV_TRACK);
    *out_state = "unknown";
    return true;
  }
  return false;
}

bool HandleNowPlaying(const std::vector<std::string>& allowed_players,
                      flutter::EncodableMap* out_map) {
  (*out_map)[flutter::EncodableValue("state")] =
      flutter::EncodableValue("unknown");
  if (allowed_players.empty()) {
    return true;
  }
#if XUNA_HAS_CPPWINRT_GSMTC
  try {
    using winrt::Windows::Media::Control::
        GlobalSystemMediaTransportControlsSessionManager;
    using winrt::Windows::Media::Control::
        GlobalSystemMediaTransportControlsSessionPlaybackStatus;

    auto manager =
        GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
    auto session = manager ? manager.GetCurrentSession() : nullptr;
    if (session == nullptr) {
      (*out_map)[flutter::EncodableValue("state")] =
          flutter::EncodableValue("stopped");
      return true;
    }

    std::string source_id =
        WideToUtf8(std::wstring(session.SourceAppUserModelId().c_str()));
    std::string lower_source = ToLowerAscii(source_id);
    std::string matched_player;
    for (const auto& allowed : allowed_players) {
      std::string needle = ToLowerAscii(allowed);
      if (!needle.empty() && lower_source.find(needle) != std::string::npos) {
        matched_player = allowed;
        break;
      }
    }
    if (matched_player.empty()) {
      (*out_map)[flutter::EncodableValue("state")] =
          flutter::EncodableValue("unknown");
      return true;
    }

    auto info = session.GetPlaybackInfo();
    std::string state_str = "unknown";
    switch (info.PlaybackStatus()) {
      case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing:
        state_str = "playing";
        break;
      case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Paused:
        state_str = "paused";
        break;
      case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Stopped:
      case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Closed:
        state_str = "stopped";
        break;
      default:
        state_str = "unknown";
        break;
    }
    (*out_map)[flutter::EncodableValue("state")] =
        flutter::EncodableValue(state_str);
    (*out_map)[flutter::EncodableValue("app")] =
        flutter::EncodableValue(TruncateUtf8(matched_player, 120));

    auto props = session.TryGetMediaPropertiesAsync().get();
    if (props != nullptr) {
      std::string title =
          TruncateUtf8(WideToUtf8(std::wstring(props.Title().c_str())), 120);
      std::string artist =
          TruncateUtf8(WideToUtf8(std::wstring(props.Artist().c_str())), 120);
      if (!title.empty()) {
        (*out_map)[flutter::EncodableValue("title")] =
            flutter::EncodableValue(title);
      }
      if (!artist.empty()) {
        (*out_map)[flutter::EncodableValue("artist")] =
            flutter::EncodableValue(artist);
      }
    }
    return true;
  } catch (...) {
    return true;
  }
#else
  return true;
#endif
}

bool SetMasterVolumeScalar(int level) {
  int clamped = std::max(0, std::min(100, level));
  float scalar = static_cast<float>(clamped) / 100.0f;

  IMMDeviceEnumerator* enumerator = nullptr;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_INPROC_SERVER,
                                __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr) || enumerator == nullptr) {
    return false;
  }

  IMMDevice* device = nullptr;
  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (FAILED(hr) || device == nullptr) {
    enumerator->Release();
    return false;
  }

  IAudioEndpointVolume* endpoint_volume = nullptr;
  hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_INPROC_SERVER,
                        nullptr, reinterpret_cast<void**>(&endpoint_volume));
  if (FAILED(hr) || endpoint_volume == nullptr) {
    device->Release();
    enumerator->Release();
    return false;
  }

  hr = endpoint_volume->SetMasterVolumeLevelScalar(scalar, nullptr);
  endpoint_volume->Release();
  device->Release();
  enumerator->Release();
  return SUCCEEDED(hr);
}

bool LaunchAppOrWorkflow(const std::string& kind, const std::string& target) {
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

  // "exe" or "lnk": launch with no command-line arguments (UDC-3 §5.3).
  SHELLEXECUTEINFOW sei = {sizeof(sei)};
  sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  sei.lpVerb = L"open";
  sei.lpFile = wtarget.c_str();
  sei.lpParameters = nullptr;
  sei.nShow = SW_SHOWNORMAL;
  return ShellExecuteExW(&sei) == TRUE;
}

bool OpenHttpsUrl(const std::string& url) {
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

std::string QueryWindowsOsVersion() {
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

std::string QueryHostname() {
  wchar_t buf[MAX_COMPUTERNAME_LENGTH + 1] = {};
  DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
  if (GetComputerNameW(buf, &size) && size > 0) {
    return TruncateUtf8(WideToUtf8(std::wstring(buf, size)), 32);
  }
  return "XUNA-PC";
}

const flutter::EncodableValue* FindKey(const flutter::EncodableMap& map,
                                       const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return nullptr;
  return &it->second;
}

void HandleMethodCallOnWorker(
    std::string method, flutter::EncodableMap args,
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

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
      CoUninitialize();
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("publicKey")] =
        flutter::EncodableValue(Base64Encode(pub65));
    result->Success(flutter::EncodableValue(out));
    CoUninitialize();
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
      CoUninitialize();
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("signature")] =
        flutter::EncodableValue(Base64Encode(sig64));
    result->Success(flutter::EncodableValue(out));
    CoUninitialize();
    return;
  }

  if (method == "media") {
    const auto* cmd_val = FindKey(args, "cmd");
    const auto* cmd_str =
        cmd_val ? std::get_if<std::string>(cmd_val) : nullptr;
    std::string state;
    if (!cmd_str || !HandleMediaCommand(*cmd_str, &state)) {
      result->Error("failed", "Media transport command failed");
      CoUninitialize();
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("state")] = flutter::EncodableValue(state);
    result->Success(flutter::EncodableValue(out));
    CoUninitialize();
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
      CoUninitialize();
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("level")] = flutter::EncodableValue(level);
    result->Success(flutter::EncodableValue(out));
    CoUninitialize();
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
    CoUninitialize();
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
      CoUninitialize();
      return;
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap()));
    CoUninitialize();
    return;
  }

  if (method == "urlOpen") {
    const auto* url_val = FindKey(args, "url");
    const auto* url_str =
        url_val ? std::get_if<std::string>(url_val) : nullptr;
    if (!url_str || !OpenHttpsUrl(*url_str)) {
      result->Error("failed", "ShellExecuteExW urlOpen failed");
      CoUninitialize();
      return;
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap()));
    CoUninitialize();
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
    CoUninitialize();
    return;
  }

  if (method == "requestPermission") {
    flutter::EncodableMap out;
    out[flutter::EncodableValue("state")] = flutter::EncodableValue("granted");
    result->Success(flutter::EncodableValue(out));
    CoUninitialize();
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
    CoUninitialize();
    return;
  }

  if (method == "showToast") {
    result->Success(flutter::EncodableValue(flutter::EncodableMap()));
    CoUninitialize();
    return;
  }

  result->NotImplemented();
  CoUninitialize();
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
        std::string method = call.method_name();
        std::thread(HandleMethodCallOnWorker, std::move(method),
                    std::move(args), std::move(shared_result))
            .detach();
      });

  // Keep the channel alive for the lifetime of the runner process.
  static auto* leaked_channel = channel.release();
  (void)leaked_channel;
}

