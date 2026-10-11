// See control_bridge.h. Only compiled on Apple.

#include "control_bridge.h"

#if defined(__APPLE__)

#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <rex/input/input_system.h>
#include <rex/logging.h>

#include "control_bridge_assignment.h"
#include "control_bridge_state.h"

namespace restreet::control {

namespace {

void AttachVirtualPads(rex::system::IInputSystem* system, const std::string& socket_path,
                       Mode mode) {
  if (system == nullptr) {
    return;
  }
  // The factory is always rex::input::CreateDefaultInputSystem for this app, so
  // the concrete type is known here (and RTTI is not required).
  auto* input = static_cast<rex::input::InputSystem*>(system);

  auto server = std::make_unique<ControlBridgeServer>();
  std::string error;
  const ControlBridgeServer::StartResult result = server->Start(socket_path, mode, &error);
  if (result != ControlBridgeServer::StartResult::kOk) {
    // Fail explicit: log and leave the default input system in place rather than
    // aborting a normal run over an optional diagnostic.
    REXLOG_ERROR("Virtual gamepad bridge disabled: {} ({})", error, socket_path);
    return;
  }

  input->AddDriver(std::make_unique<VirtualPadDriver>(std::move(server)));
  input->SetDeviceAssignment(std::make_unique<VirtualPadAssignment>(mode));
  REXLOG_INFO("Virtual gamepad bridge: socket {} mode {}", socket_path, ModeName(mode));
}

}  // namespace

VirtualPadDriver::VirtualPadDriver(std::unique_ptr<ControlBridgeServer> server)
    : InputDriver(nullptr, 0), server_(std::move(server)) {}

X_STATUS VirtualPadDriver::Setup() { return X_STATUS_SUCCESS; }

int VirtualPadDriver::PlayerFor(rex::input::DeviceId id) const {
  if (server_ == nullptr) {
    return -1;
  }
  for (int player = 0; player < kPlayerCount; ++player) {
    if (id != static_cast<rex::input::DeviceId>(DeviceIdForPlayer(player))) {
      continue;
    }
    // A pad that this mode does not expose is reported not connected, matching
    // EnumerateDevices, so presence and routing cannot disagree.
    return PlayerBridged(server_->mode(), player) ? player : -1;
  }
  return -1;
}

void VirtualPadDriver::EnumerateDevices(std::vector<rex::input::DeviceInfo>& out) {
  if (server_ == nullptr) {
    return;
  }
  for (int player = 0; player < kPlayerCount; ++player) {
    if (!PlayerBridged(server_->mode(), player)) {
      continue;
    }
    rex::input::DeviceInfo info;
    info.id = static_cast<rex::input::DeviceId>(DeviceIdForPlayer(player));
    info.name = "Virtual Gamepad " + std::to_string(player);
    info.guid = "restreet-virtual-pad-" + std::to_string(player);
    info.synthetic = true;  // rides the synthetic path, routed by our assignment
    out.push_back(std::move(info));
  }
}

X_RESULT VirtualPadDriver::GetDeviceState(rex::input::DeviceId id,
                                          rex::input::X_INPUT_STATE* out_state) {
  const int player = PlayerFor(id);
  if (server_ == nullptr || player < 0) {
    return X_ERROR_DEVICE_NOT_CONNECTED;
  }
  // Never logs per poll: the guest polls this every frame.
  const PadOutput output = server_->Read(player, ControlBridgeServer::NowMs());
  WriteGuestState(output, out_state);
  return X_ERROR_SUCCESS;
}

X_RESULT VirtualPadDriver::GetDeviceCapabilities(rex::input::DeviceId id, uint32_t /*flags*/,
                                                 rex::input::X_INPUT_CAPABILITIES* out_caps) {
  if (server_ == nullptr || PlayerFor(id) < 0) {
    return X_ERROR_DEVICE_NOT_CONNECTED;
  }
  if (out_caps != nullptr) {
    std::memset(out_caps, 0, sizeof(*out_caps));
    out_caps->type = 0x01;      // XINPUT_DEVTYPE_GAMEPAD
    out_caps->sub_type = 0x01;  // XINPUT_DEVSUBTYPE_GAMEPAD
    out_caps->flags = 0;
    out_caps->gamepad.buttons = 0xFFFF;
    out_caps->gamepad.left_trigger = 0xFF;
    out_caps->gamepad.right_trigger = 0xFF;
    out_caps->gamepad.thumb_lx = static_cast<int16_t>(0x7FFF);
    out_caps->gamepad.thumb_ly = static_cast<int16_t>(0x7FFF);
    out_caps->gamepad.thumb_rx = static_cast<int16_t>(0x7FFF);
    out_caps->gamepad.thumb_ry = static_cast<int16_t>(0x7FFF);
    // A virtual pad has no motors; report the same all-FFB capability the other
    // synthetic drivers report and accept vibration without a physical effect.
    out_caps->vibration.left_motor_speed = 0xFFFF;
    out_caps->vibration.right_motor_speed = 0xFFFF;
  }
  return X_ERROR_SUCCESS;
}

X_RESULT VirtualPadDriver::SetDeviceVibration(rex::input::DeviceId id,
                                              rex::input::X_INPUT_VIBRATION* /*vibration*/) {
  if (server_ == nullptr || PlayerFor(id) < 0) {
    return X_ERROR_DEVICE_NOT_CONNECTED;
  }
  // Acknowledged; there is no physical device to drive.
  return X_ERROR_SUCCESS;
}

X_RESULT VirtualPadDriver::GetDeviceKeystroke(rex::input::DeviceId id, uint32_t /*flags*/,
                                              rex::input::X_INPUT_KEYSTROKE* /*out_keystroke*/) {
  if (server_ == nullptr || PlayerFor(id) < 0) {
    return X_ERROR_DEVICE_NOT_CONNECTED;
  }
  // The game polls GetState; there is no keyboard queue for a virtual pad.
  return X_ERROR_EMPTY;
}

void InstallControlBridge(rex::RuntimeConfig& config) {
  if (config.tool_mode) {
    return;
  }
  const char* socket_env = std::getenv("RESTREET_CONTROL_SOCKET");
  if (socket_env == nullptr || socket_env[0] == '\0') {
    return;  // Opt-in off: the default factory is left byte-for-byte untouched.
  }
  const std::string socket_path = socket_env;
  const Mode mode = ModeFromName(std::getenv("RESTREET_CONTROL_MODE"));

  auto base = config.input_factory;
  config.input_factory = [base, socket_path, mode](
                             bool tool_mode) -> std::unique_ptr<rex::system::IInputSystem> {
    std::unique_ptr<rex::system::IInputSystem> system =
        base ? base(tool_mode) : rex::input::CreateDefaultInputSystem(tool_mode);
    if (!tool_mode) {
      AttachVirtualPads(system.get(), socket_path, mode);
    }
    return system;
  };
}

}  // namespace restreet::control

#endif  // defined(__APPLE__)
