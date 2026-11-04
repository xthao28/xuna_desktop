#ifndef RUNNER_XUNA_WIN_CRYPTO_MEDIA_H_
#define RUNNER_XUNA_WIN_CRYPTO_MEDIA_H_

#include "xuna_win_common.h"

namespace xuna_win {

// Opens or creates a non-exportable P-256 key in CNG (preferring TPM
// MS_PLATFORM_CRYPTO_PROVIDER, falling back to MS_KEY_STORAGE_PROVIDER).
inline bool OpenOrCreateCngP256Key(NCRYPT_PROV_HANDLE* out_prov,
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

inline bool ExportUncompressedPublicKey65(NCRYPT_KEY_HANDLE key,
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

inline bool ComputeSha256(const std::vector<uint8_t>& message,
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

inline bool SignMessageCngP256(const std::vector<uint8_t>& message,
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

inline void SendMediaVirtualKey(WORD vk) {
  INPUT inputs[2] = {};
  inputs[0].type = INPUT_KEYBOARD;
  inputs[0].ki.wVk = vk;
  inputs[1].type = INPUT_KEYBOARD;
  inputs[1].ki.wVk = vk;
  inputs[1].ki.dwFlags = KEYEVENTF_KEYUP;
  SendInput(2, inputs, sizeof(INPUT));
}

inline bool HandleMediaCommand(const std::string& cmd, std::string* out_state) {
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

inline bool HandleNowPlaying(const std::vector<std::string>& allowed_players,
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

inline bool SetMasterVolumeScalar(int level) {
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

}  // namespace xuna_win

#endif  // RUNNER_XUNA_WIN_CRYPTO_MEDIA_H_
