# XUNA Desktop — Linux GTK Runner Scaffold (`xuna/host`)

This directory contains the native Linux GTK `MethodChannel("xuna/host")` plugin scaffold (`xuna_host_plugin.h` and `xuna_host_plugin.cc`) matching the 18 canonical methods defined in `lib/core/channel/xuna_host_channel.dart` and `UDC-3-desktop-agent.md` §5.6.3.

## Wiring into the Flutter Linux Runner

When generating or building the Linux GTK runner (`flutter create --platforms=linux .`), register the plugin inside `linux/runner/my_application.cc` right after `fl_register_plugins(FL_PLUGIN_REGISTRY(view))`:

```cpp
#include "xuna_host_plugin.h"

// Inside my_application_activate(GApplication* application):
fl_register_plugins(FL_PLUGIN_REGISTRY(view));
xuna_host_plugin_register_with_messenger(
    fl_engine_get_binary_messenger(fl_view_get_engine(view)));
```

And add `runner/xuna_host_plugin.cc` to `linux/CMakeLists.txt` (`target_sources(${BINARY_NAME} PRIVATE "runner/xuna_host_plugin.cc")`).

## Method Table (18 Methods)

| # | Method | Linux Native Provider Target | Scaffold Behavior (ECO-S4) |
|---|---|---|---|
| 1 | `keyEnsure` | `libsecret` / TPM2 PKCS#11 P-256 key | Returns `unsupported` |
| 2 | `keySign` | OpenSSL / TPM2 ECDSA P-256 `r \|\| s` | Validates args, returns `unsupported` |
| 3 | `media` | MPRIS2 D-Bus `org.mpris.MediaPlayer2.Player` | Validates cmd, returns `unsupported` |
| 4 | `volumeSet` | PipeWire / PulseAudio sink volume (`0..100`) | Validates range, returns `unsupported` |
| 5 | `nowPlaying` | MPRIS2 D-Bus `Metadata` + `PlaybackStatus` | Returns `{"state": "stopped"}` |
| 6 | `appLaunch` | `GDesktopAppInfo` argument-free launch | Validates args, returns `unsupported` |
| 7 | `urlOpen` | `g_app_info_launch_default_for_uri` (`https://` only) | Implemented (`https://` enforced) |
| 8 | `browserCurrentUrl` | AT-SPI2 address-bar inspection | Returns `unsupported` |
| 9 | `workflowRun` | Allowlisted `.desktop` action (no shell) | Validates args, returns `unsupported` |
| 10 | `permissions` | AT-SPI2 + `org.freedesktop.Notifications` | Returns `granted` snapshot |
| 11 | `requestPermission` | Portal / AT-SPI2 permission check | Returns `{"state": "granted"}` |
| 12 | `hostInfo` | `uname(2)` + `gethostname(2)` | Implemented (`platform: "linux"`) |
| 13 | `showToast` | `org.freedesktop.Notifications` D-Bus | Validates args, returns `{}` |
| 14 | `displayWake` | `org.freedesktop.ScreenSaver` D-Bus | Returns `unsupported` |
| 15 | `clipboardReadText` | `GtkClipboard` / `GdkClipboard` | Returns `unsupported` |
| 16 | `lockScreen` | `org.freedesktop.login1.Session.Lock` | Returns `unsupported` |
| 17 | `readActiveWindowContext` | AT-SPI2 active window & focused control | Returns `unsupported` |
| 18 | `readBrowserPageSummary` | AT-SPI2 semantic browser summary | Returns `unsupported` |
