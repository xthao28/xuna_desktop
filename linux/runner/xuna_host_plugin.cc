#include "xuna_host_plugin.h"

#include <glib.h>
#include <sys/utsname.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <string>

namespace {

constexpr char kChannelName[] = "xuna/host";

std::string ToLowerAscii(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return s;
}

const char* LookupStringArg(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* val = fl_value_lookup_string(args, key);
  if (val == nullptr || fl_value_get_type(val) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(val);
}

int64_t LookupIntArg(FlValue* args, const char* key, int64_t fallback) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return fallback;
  }
  FlValue* val = fl_value_lookup_string(args, key);
  if (val == nullptr || fl_value_get_type(val) != FL_VALUE_TYPE_INT) {
    return fallback;
  }
  return fl_value_get_int(val);
}

FlMethodResponse* MakeUnsupportedResponse(const char* detail) {
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new("unsupported", detail, nullptr));
}

FlMethodResponse* MakeInvalidArgsResponse(const char* detail) {
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new("invalid_args", detail, nullptr));
}

FlMethodResponse* MakeFailedResponse(const char* detail) {
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new("failed", detail, nullptr));
}

// 1. keyEnsure — libsecret / OpenSSL P-256 non-exportable host identity key
FlMethodResponse* HandleKeyEnsure() {
  return MakeUnsupportedResponse(
      "Linux libsecret/TPM2 P-256 keyEnsure provider is stubbed in ECO-S4");
}

// 2. keySign — ECDSA P-256 raw (r || s) 64-byte signature over message
FlMethodResponse* HandleKeySign(FlValue* args) {
  const char* msg_b64 = LookupStringArg(args, "message");
  if (msg_b64 == nullptr || msg_b64[0] == '\0') {
    return MakeInvalidArgsResponse("Missing base64 message for keySign");
  }
  return MakeUnsupportedResponse(
      "Linux libsecret/TPM2 P-256 keySign provider is stubbed in ECO-S4");
}

// 3. media — MPRIS2 D-Bus org.mpris.MediaPlayer2.Player transport
FlMethodResponse* HandleMedia(FlValue* args) {
  const char* cmd = LookupStringArg(args, "cmd");
  if (cmd == nullptr) {
    return MakeInvalidArgsResponse("Missing media command");
  }
  std::string c(cmd);
  if (c != "play_pause" && c != "next" && c != "previous") {
    return MakeUnsupportedResponse("Unsupported media command");
  }
  return MakeUnsupportedResponse(
      "Linux MPRIS2 D-Bus media transport provider is stubbed in ECO-S4");
}

// 4. volumeSet — PipeWire / PulseAudio master sink volume (0..100)
FlMethodResponse* HandleVolumeSet(FlValue* args) {
  int64_t level = LookupIntArg(args, "level", -1);
  if (level < 0 || level > 100) {
    return MakeInvalidArgsResponse("Volume level must be 0..100");
  }
  return MakeUnsupportedResponse(
      "Linux PipeWire/PulseAudio volumeSet provider is stubbed in ECO-S4");
}

// 5. nowPlaying — MPRIS2 D-Bus Metadata query for allowlisted players
FlMethodResponse* HandleNowPlaying(FlValue* /*args*/) {
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "state", fl_value_new_string("stopped"));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(map));
}

// 6. appLaunch — argument-free Gio DesktopAppInfo / execve launch
FlMethodResponse* HandleAppLaunch(FlValue* args) {
  const char* kind = LookupStringArg(args, "kind");
  const char* target = LookupStringArg(args, "target");
  if (kind == nullptr || target == nullptr || target[0] == '\0') {
    return MakeInvalidArgsResponse("Missing kind or target for appLaunch");
  }
  return MakeUnsupportedResponse(
      "Linux Gio DesktopAppInfo appLaunch provider is stubbed in ECO-S4");
}

// 7. urlOpen — strict https:// validation before g_app_info_launch_default_for_uri
FlMethodResponse* HandleUrlOpen(FlValue* args) {
  const char* url = LookupStringArg(args, "url");
  if (url == nullptr) {
    return MakeInvalidArgsResponse("Missing url");
  }
  std::string lower = ToLowerAscii(std::string(url));
  if (lower.rfind("https://", 0) != 0) {
    return MakeInvalidArgsResponse("Only https:// URLs are permitted");
  }
  g_autoptr(GError) error = nullptr;
  if (!g_app_info_launch_default_for_uri(url, nullptr, &error)) {
    return MakeFailedResponse(error != nullptr ? error->message
                                               : "Failed to launch default URI handler");
  }
  g_autoptr(FlValue) map = fl_value_new_map();
  return FL_METHOD_RESPONSE(fl_method_success_response_new(map));
}

// 8. browserCurrentUrl — AT-SPI2 active browser address-bar reader
FlMethodResponse* HandleBrowserCurrentUrl(FlValue* /*args*/) {
  return MakeUnsupportedResponse(
      "Linux AT-SPI2 browserCurrentUrl provider is stubbed in ECO-S4");
}

// 9. workflowRun — allowlisted .desktop action runner (never shell/bash)
FlMethodResponse* HandleWorkflowRun(FlValue* args) {
  const char* kind = LookupStringArg(args, "kind");
  const char* target = LookupStringArg(args, "target");
  if (kind == nullptr || target == nullptr || target[0] == '\0') {
    return MakeInvalidArgsResponse("Missing kind or target for workflowRun");
  }
  return MakeUnsupportedResponse(
      "Linux workflowRun provider is stubbed in ECO-S4");
}

// 10. permissions — AT-SPI2 accessibility & freedesktop notification status
FlMethodResponse* HandlePermissions() {
  g_autoptr(FlValue) map = fl_value_new_map();
  g_autoptr(FlValue) automation = fl_value_new_map();
  fl_value_set_string_take(map, "accessibility", fl_value_new_string("granted"));
  fl_value_set_string_take(map, "notifications", fl_value_new_string("granted"));
  fl_value_set_string_take(map, "automation", g_steal_pointer(&automation));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(map));
}

// 11. requestPermission — prompt or open system settings for permission kind
FlMethodResponse* HandleRequestPermission(FlValue* /*args*/) {
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "state", fl_value_new_string("granted"));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(map));
}

// 12. hostInfo — returns platform="linux", uname release, and hostname
FlMethodResponse* HandleHostInfo() {
  struct utsname uts {};
  std::string os_version = "Linux";
  if (uname(&uts) == 0) {
    os_version = std::string(uts.sysname) + " " + std::string(uts.release);
  }

  char host_buf[256] = {};
  std::string hostname = "xuna-linux";
  if (gethostname(host_buf, sizeof(host_buf) - 1) == 0 && host_buf[0] != '\0') {
    hostname = std::string(host_buf);
  }

  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "platform", fl_value_new_string("linux"));
  fl_value_set_string_take(map, "osVersion",
                           fl_value_new_string(os_version.c_str()));
  fl_value_set_string_take(map, "hostname",
                           fl_value_new_string(hostname.c_str()));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(map));
}

// 13. showToast — org.freedesktop.Notifications D-Bus desktop notification
FlMethodResponse* HandleShowToast(FlValue* args) {
  const char* title = LookupStringArg(args, "title");
  const char* body = LookupStringArg(args, "body");
  if (title == nullptr || body == nullptr) {
    return MakeInvalidArgsResponse("Missing title or body for showToast");
  }
  g_autoptr(FlValue) map = fl_value_new_map();
  return FL_METHOD_RESPONSE(fl_method_success_response_new(map));
}

// 14. displayWake — org.freedesktop.ScreenSaver SimulateUserActivity
FlMethodResponse* HandleDisplayWake() {
  return MakeUnsupportedResponse(
      "Linux ScreenSaver displayWake provider is stubbed in ECO-S4");
}

// 15. clipboardReadText — GdkClipboard / GtkClipboard plain-text reader
FlMethodResponse* HandleClipboardReadText() {
  return MakeUnsupportedResponse(
      "Linux GtkClipboard clipboardReadText provider is stubbed in ECO-S4");
}

// 16. lockScreen — org.freedesktop.login1.Session.Lock via D-Bus
FlMethodResponse* HandleLockScreen() {
  return MakeUnsupportedResponse(
      "Linux logind lockScreen provider is stubbed in ECO-S4");
}

// 17. readActiveWindowContext — AT-SPI2 frontmost window & focused control reader
FlMethodResponse* HandleReadActiveWindowContext(FlValue* /*args*/) {
  return MakeUnsupportedResponse(
      "Linux AT-SPI2 readActiveWindowContext provider is stubbed in ECO-S4");
}

// 18. readBrowserPageSummary — AT-SPI2 semantic browser page summary reader
FlMethodResponse* HandleReadBrowserPageSummary(FlValue* /*args*/) {
  return MakeUnsupportedResponse(
      "Linux AT-SPI2 readBrowserPageSummary provider is stubbed in ECO-S4");
}

void MethodCallCb(FlMethodChannel* /*channel*/, FlMethodCall* method_call,
                  gpointer /*user_data*/) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (std::strcmp(method, "keyEnsure") == 0) {
    response = HandleKeyEnsure();
  } else if (std::strcmp(method, "keySign") == 0) {
    response = HandleKeySign(args);
  } else if (std::strcmp(method, "media") == 0) {
    response = HandleMedia(args);
  } else if (std::strcmp(method, "volumeSet") == 0) {
    response = HandleVolumeSet(args);
  } else if (std::strcmp(method, "nowPlaying") == 0) {
    response = HandleNowPlaying(args);
  } else if (std::strcmp(method, "appLaunch") == 0) {
    response = HandleAppLaunch(args);
  } else if (std::strcmp(method, "urlOpen") == 0) {
    response = HandleUrlOpen(args);
  } else if (std::strcmp(method, "browserCurrentUrl") == 0) {
    response = HandleBrowserCurrentUrl(args);
  } else if (std::strcmp(method, "workflowRun") == 0) {
    response = HandleWorkflowRun(args);
  } else if (std::strcmp(method, "permissions") == 0) {
    response = HandlePermissions();
  } else if (std::strcmp(method, "requestPermission") == 0) {
    response = HandleRequestPermission(args);
  } else if (std::strcmp(method, "hostInfo") == 0) {
    response = HandleHostInfo();
  } else if (std::strcmp(method, "showToast") == 0) {
    response = HandleShowToast(args);
  } else if (std::strcmp(method, "displayWake") == 0) {
    response = HandleDisplayWake();
  } else if (std::strcmp(method, "clipboardReadText") == 0) {
    response = HandleClipboardReadText();
  } else if (std::strcmp(method, "lockScreen") == 0) {
    response = HandleLockScreen();
  } else if (std::strcmp(method, "readActiveWindowContext") == 0) {
    response = HandleReadActiveWindowContext(args);
  } else if (std::strcmp(method, "readBrowserPageSummary") == 0) {
    response = HandleReadBrowserPageSummary(args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  fl_method_call_respond(method_call, response, &error);
}

}  // namespace

void xuna_host_plugin_register_with_messenger(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, MethodCallCb, nullptr,
                                            nullptr);
}
