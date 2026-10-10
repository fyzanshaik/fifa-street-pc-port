// Maps a bridge PadOutput onto the big-endian guest X_INPUT_STATE.
//
// Split out of the driver so it can be unit-tested without the ReXGlue runtime
// library: it only needs <rex/input/input.h>, which is header-only. The
// per-field assignment is what makes the guest see big-endian bytes, because
// X_INPUT_STATE's fields are rex be<> wrappers.

#pragma once

#include <cstring>

#include <rex/input/input.h>

#include "control_protocol.h"

namespace restreet::control {

inline void WriteGuestState(const PadOutput& output, rex::input::X_INPUT_STATE* state) {
  if (state == nullptr) {
    return;
  }
  std::memset(state, 0, sizeof(*state));
  state->packet_number = output.packet;
  state->gamepad.buttons = output.sample.buttons;
  state->gamepad.left_trigger = output.sample.left_trigger;
  state->gamepad.right_trigger = output.sample.right_trigger;
  state->gamepad.thumb_lx = output.sample.thumb_lx;
  state->gamepad.thumb_ly = output.sample.thumb_ly;
  state->gamepad.thumb_rx = output.sample.thumb_rx;
  state->gamepad.thumb_ry = output.sample.thumb_ry;
}

}  // namespace restreet::control
