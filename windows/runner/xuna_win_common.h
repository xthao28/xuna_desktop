#ifndef RUNNER_XUNA_WIN_COMMON_H_
#define RUNNER_XUNA_WIN_COMMON_H_

#include <windows.h>
#include <bcrypt.h>
#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <ncrypt.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <uiautomation.h>
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

#if __has_include(<winrt/Windows.Data.Xml.Dom.h>) && \
    __has_include(<winrt/Windows.UI.Notifications.h>)
#define XUNA_HAS_CPPWINRT_TOAST 1
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>
#else
#define XUNA_HAS_CPPWINRT_TOAST 0
#endif

#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace xuna_win {

constexpr wchar_t kXunaKeyName[] = L"XunaHostIdentityP256_v1";

using NTSTATUS_T = LONG;
using RtlGetVersionFn = NTSTATUS_T(WINAPI*)(PRTL_OSVERSIONINFOW);

inline std::wstring Utf8ToWide(const std::string& str) {
  if (str.empty()) return std::wstring();
  int size_needed = MultiByteToWideChar(
      CP_UTF8, 0, str.data(), static_cast<int>(str.size()), nullptr, 0);
  if (size_needed <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(size_needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, str.data(), static_cast<int>(str.size()),
                      out.data(), size_needed);
  return out;
}

inline std::string WideToUtf8(const std::wstring& wstr) {
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

inline std::string Base64Encode(const std::vector<uint8_t>& bytes) {
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

inline bool Base64Decode(const std::string& input, std::vector<uint8_t>* out) {
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

inline std::string ToLowerAscii(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return s;
}

inline std::string TruncateUtf8(const std::string& s, size_t max_chars) {
  if (s.size() <= max_chars) return s;
  return s.substr(0, max_chars);
}

inline std::string CompactAlphaNumLower(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (unsigned char c : s) {
    if (std::isalnum(c)) {
      out.push_back(static_cast<char>(std::tolower(c)));
    }
  }
  return out;
}

inline std::vector<std::string> SplitAlphaNumTokens(const std::string& s) {
  std::vector<std::string> tokens;
  std::string cur;
  for (unsigned char c : s) {
    if (std::isalnum(c)) {
      cur.push_back(static_cast<char>(std::tolower(c)));
    } else if (!cur.empty()) {
      tokens.push_back(cur);
      cur.clear();
    }
  }
  if (!cur.empty()) tokens.push_back(cur);
  return tokens;
}

inline int ScoreCandidateName(const std::string& candidate_raw,
                              const std::string& query_lower,
                              const std::string& query_compact,
                              const std::vector<std::string>& query_tokens) {
  if (candidate_raw.empty() || query_compact.empty()) return 0;
  std::string cand_lower = ToLowerAscii(candidate_raw);
  std::string cand_compact = CompactAlphaNumLower(candidate_raw);
  if (cand_lower == query_lower || cand_compact == query_compact) {
    return 100;
  }
  std::vector<std::string> words = SplitAlphaNumTokens(candidate_raw);
  std::string initials;
  for (const auto& w : words) {
    if (!w.empty()) initials.push_back(w[0]);
  }
  std::string initials_plus_last;
  if (words.size() >= 2) {
    for (size_t i = 0; i + 1 < words.size(); ++i) {
      initials_plus_last.push_back(words[i][0]);
    }
    initials_plus_last += words.back();
  }
  if (!initials_plus_last.empty() &&
      (query_compact == initials_plus_last ||
       initials_plus_last.rfind(query_compact, 0) == 0)) {
    return 92;
  }
  if (initials.size() >= 2 && query_compact == initials) {
    return 88;
  }
  if (cand_lower.rfind(query_lower, 0) == 0 ||
      cand_compact.rfind(query_compact, 0) == 0) {
    return 82;
  }
  if (cand_lower.find(query_lower) != std::string::npos ||
      cand_compact.find(query_compact) != std::string::npos) {
    return 72;
  }
  int hits = 0;
  for (const auto& t : query_tokens) {
    if (cand_lower.find(t) != std::string::npos ||
        cand_compact.find(t) != std::string::npos) {
      ++hits;
    }
  }
  if (!query_tokens.empty() &&
      hits == static_cast<int>(query_tokens.size())) {
    return 65 + hits * 5;
  }
  return hits * 25;
}

inline const flutter::EncodableValue* FindKey(const flutter::EncodableMap& map,
                                              const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return nullptr;
  return &it->second;
}

struct ScopedComInitializer {
  HRESULT hr;
  ScopedComInitializer()
      : hr(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)) {}
  ~ScopedComInitializer() {
    if (SUCCEEDED(hr)) {
      CoUninitialize();
    }
  }
  ScopedComInitializer(const ScopedComInitializer&) = delete;
  ScopedComInitializer& operator=(const ScopedComInitializer&) = delete;
};

}  // namespace xuna_win

#endif  // RUNNER_XUNA_WIN_COMMON_H_
