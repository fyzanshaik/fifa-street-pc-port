// Mac-only virtual-gamepad bridge: SDK InputDriver + runtime wiring.
//
// The bridge is opt-in. RESTREET_CONTROL_SOCKET names an absolute Unix-domain
// socket; when it is unset, OnPreSetup leaves config.input_factory exactly as
// the SDK set it, so a normal run starts no thread and binds no socket.
//
// When it is set, InstallControlBridge wraps the factory: the default input
// system is built as usual, then the virtual-pad driver is added and the device
// assignment is replaced with one that scopes the pads to explicit guest users
// (see control_bridge_assignment.h). This happens inside the factory, before
// the runtime returns and long before the guest starts polling.

#pragma once

#include <rex/runtime.h>

#if defined(__APPLE__)

#include <memory>
#include <vector>

#include <rex/input/input_driver.h>

#include "control_bridge_server.h"

namespace restreet::control {

// X_STATUS/X_RESULT live in namespace rex; the X_*_SUCCESS-style macros expand
// to an unqualified cast, so bring the types into scope for those macros.
using rex::X_RESULT;
using rex::X_STATUS;

class VirtualPadDriver final : public rex::input::InputDriver {
 public:
  explicit VirtualPadDriver(std::unique_ptr<ControlBridgeServer> server);

  X_STATUS Setup() override;
  void EnumerateDevices(std::vector<rex::input::DeviceInfo>& out) override;
  X_RESULT GetDeviceState(rex::input::DeviceId id, rex::input::X_INPUT_STATE* out_state) override;
  X_RESULT GetDeviceCapabilities(rex::input::DeviceId id, uint32_t flags,
                                 rex::input::X_INPUT_CAPABILITIES* out_caps) override;
  X_RESULT SetDeviceVibration(rex::input::DeviceId id,
                              rex::input::X_INPUT_VIBRATION* vibration) override;
  X_RESULT GetDeviceKeystroke(rex::input::DeviceId id, uint32_t flags,
                              rex::input::X_INPUT_KEYSTROKE* out_keystroke) override;

 private:
  int PlayerFor(rex::input::DeviceId id) const;

  std::unique_ptr<ControlBridgeServer> server_;
};

// Wraps config.input_factory when the opt-in is set; a no-op otherwise.
void InstallControlBridge(rex::RuntimeConfig& config);

}  // namespace restreet::control

#else

namespace restreet::control {
// Non-Apple: no bridge, no state, no override.
inline void InstallControlBridge(rex::RuntimeConfig&) {}
}  // namespace restreet::control

#endif
