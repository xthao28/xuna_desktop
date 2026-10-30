#ifndef RUNNER_XUNA_HOST_PLUGIN_H_
#define RUNNER_XUNA_HOST_PLUGIN_H_

#include <flutter/binary_messenger.h>

// Registers the native "xuna/host" MethodChannel on the Windows Flutter engine
// (UDC-3 §5.6.3).
void RegisterXunaHostPlugin(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_XUNA_HOST_PLUGIN_H_

