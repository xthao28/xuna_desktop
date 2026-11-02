#ifndef RUNNER_XUNA_HOST_PLUGIN_H_
#define RUNNER_XUNA_HOST_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

// Registers the native "xuna/host" MethodChannel on the Linux GTK Flutter
// engine (UDC-3 §5.6.3, ECO-S4 Linux scaffold).
//
// Exposes the 18 canonical methods required by MethodChannelXunaHostChannel:
//   1. keyEnsure
//   2. keySign
//   3. media
//   4. volumeSet
//   5. nowPlaying
//   6. appLaunch
//   7. urlOpen
//   8. browserCurrentUrl
//   9. workflowRun
//  10. permissions
//  11. requestPermission
//  12. hostInfo
//  13. showToast
//  14. displayWake
//  15. clipboardReadText
//  16. lockScreen
//  17. readActiveWindowContext
//  18. readBrowserPageSummary
void xuna_host_plugin_register_with_messenger(FlBinaryMessenger* messenger);

G_END_DECLS

#endif  // RUNNER_XUNA_HOST_PLUGIN_H_
