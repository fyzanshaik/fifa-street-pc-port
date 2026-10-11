// Device-assignment policy for the virtual gamepad bridge.
//
// The SDK's default SlotAssignment routes every synthetic device to guest user
// 0 (and physical pads by ordinal), which would collapse both virtual pads onto
// player one. This policy instead maps the bridge's own device ids to explicit
// guest users and decides what to do with every other device:
//
//   ai-ai    : only the virtual pads are routed; foreign devices are dropped so
//              a physical pad or the keyboard can never contaminate a slot.
//   human-ai : virtual pad 1 is routed to user 1; the remaining devices follow
//              the SDK default (synthetic -> user 0, physical by ordinal), so
//              normal physical/keyboard play on user 0 is unchanged.
//   agent-cpu: exactly like ai-ai, but only virtual pad 0 exists, so this policy
//              assigns no device to guest user 1. Team/CPU setup remains game
//              configuration and is unverified here.
//
// Only the fmt-free SDK input headers are used, so this file unit-tests without
// the ReXGlue runtime library.

#pragma once

#include <array>
#include <vector>

#include <rex/input/device.h>
#include <rex/input/device_assignment.h>

#include "control_protocol.h"

namespace restreet::control {

class VirtualPadAssignment final : public rex::input::DeviceAssignment {
 public:
  explicit VirtualPadAssignment(Mode mode) : mode_(mode) {}

  void OnDevicesChanged(const std::vector<rex::input::DeviceInfo>& devices) override {
    for (auto& user : users_) {
      user.clear();
    }
    for (const auto& device : devices) {
      const int player = PlayerForDevice(device.id);
      if (player >= 0) {
        // A bridge device: route it only to its own bridged slot. It never falls
        // through to the foreign path, even when its slot is not bridged.
        if (PlayerBridged(mode_, player)) {
          users_[player].push_back(device.id);
        }
        continue;
      }
      if (mode_ == Mode::kHumanAi) {
        // Mirror the SDK default: synthetic devices feed user 0, physical pads
        // feed the user matching their connection ordinal.
        if (device.synthetic) {
          users_[0].push_back(device.id);
        } else if (device.ordinal < rex::input::kMaxGuestUsers) {
          users_[device.ordinal].push_back(device.id);
        }
      }
      // ai-ai drops every foreign device.
    }
  }

  void DevicesForUser(uint32_t user_index, std::vector<rex::input::DeviceId>& out) const override {
    out.clear();
    if (user_index >= rex::input::kMaxGuestUsers) {
      return;
    }
    out = users_[user_index];
  }

 private:
  static int PlayerForDevice(rex::input::DeviceId id) {
    for (int player = 0; player < kPlayerCount; ++player) {
      if (id == static_cast<rex::input::DeviceId>(DeviceIdForPlayer(player))) {
        return player;
      }
    }
    return -1;
  }

  Mode mode_;
  std::array<std::vector<rex::input::DeviceId>, rex::input::kMaxGuestUsers> users_;
};

}  // namespace restreet::control
