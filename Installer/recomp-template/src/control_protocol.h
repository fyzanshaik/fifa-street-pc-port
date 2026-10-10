// Virtual-gamepad control protocol for the macOS AI-evaluation bridge.
//
// Runtime-free and dependency-free: this header only needs <cstdint>/<cstddef>
// and a C++ standard library, so it can be compiled and unit-tested without the
// ReXGlue SDK, generated guest code or a GPU. It defines the small, versioned,
// fixed-layout local message protocol and the latching pad state that the
// receiver thread mutates and the guest poll reads.
//
// Everything here is deliberately explicit about byte order rather than
// memcpy-ing a struct, so the wire format is identical on any host and cannot
// drift with a compiler's padding choices. The guest-facing structs
// (rex::input::X_INPUT_STATE) are big-endian; this protocol is little-endian
// because it is a host-local control channel, and the adapter converts.

#pragma once

#include <cstddef>
#include <cstdint>

namespace restreet::control {

// "RSTP" - ReStreet virtual Pad. Present on every request and response.
constexpr uint32_t kMagic = 0x52535450u;
constexpr uint8_t kProtocolVersion = 1;

// Fixed frame sizes: the receiver always consumes exactly one request frame per
// message, so a malformed frame cannot desynchronise the stream.
constexpr size_t kRequestBytes = 24;
constexpr size_t kResponseBytes = 16;

// Upper bound on a hold, so a malformed/large TTL cannot park a button for an
// unbounded time. Longer holds are clamped to this value.
constexpr uint32_t kMaxHoldMs = 10u * 60u * 1000u;

// Number of bridgeable players. Guest user indices 0 and 1.
constexpr int kPlayerCount = 2;

// Unique driver-scoped device-id namespace ("RSETPAD\0"): distinct from the
// SDK's NOP (0x4E4F5000) and MnK (0x4D4E4B00) ids, so a virtual pad can never
// alias an existing device.
constexpr uint64_t kDeviceIdBase = 0x5253455450414400ull;

constexpr uint64_t DeviceIdForPlayer(int player) {
  return kDeviceIdBase | static_cast<uint64_t>(static_cast<unsigned>(player));
}

// Which virtual pads the bridge exposes. Deliberately explicit: there is no
// silent physical-pad fallback in ai-ai mode.
enum class Mode {
  // Virtual pads on guest user 0 and 1. Physical/keyboard devices are dropped
  // so they cannot contaminate either slot.
  kAiAi,
  // Existing physical/keyboard/synthetic devices route as the SDK default
  // (user 0); only virtual pad 1 is added, on guest user 1. Keyboard-as-player-1
  // is not implemented and is not claimed.
  kHumanAi,
};

constexpr const char* ModeName(Mode mode) {
  return mode == Mode::kAiAi ? "ai-ai" : "human-ai";
}

// True when a player's virtual pad is exposed to the guest in this mode.
constexpr bool PlayerBridged(Mode mode, int player) {
  if (player == 0) return mode == Mode::kAiAi;
  if (player == 1) return true;
  return false;
}

enum class Command : uint8_t {
  kSetState = 1,  // replace the whole gamepad sample
  kPress = 2,     // OR the given buttons into the current sample
  kRelease = 3,   // clear the given buttons (0 = clear all)
  kPing = 4,      // report the current effective sample, change nothing
};

enum class Status : uint8_t {
  kOk = 0,
  kBadMagic = 1,
  kBadVersion = 2,
  kBadLength = 3,
  kBadCommand = 4,
  kBadPlayer = 5,
  kPlayerNotBridged = 6,
};

constexpr const char* StatusName(Status status) {
  switch (status) {
    case Status::kOk: return "ok";
    case Status::kBadMagic: return "bad_magic";
    case Status::kBadVersion: return "bad_version";
    case Status::kBadLength: return "bad_length";
    case Status::kBadCommand: return "bad_command";
    case Status::kBadPlayer: return "bad_player";
    case Status::kPlayerNotBridged: return "player_not_bridged";
  }
  return "unknown";
}

// Host-neutral gamepad sample. Button bits use the XInput numeric values (the
// same numbers as rex::input::X_INPUT_GAMEPAD_BUTTON); sticks are signed 16-bit
// and triggers unsigned 8-bit, matching the guest state.
struct PadSample {
  uint16_t buttons = 0;
  uint8_t left_trigger = 0;
  uint8_t right_trigger = 0;
  int16_t thumb_lx = 0;
  int16_t thumb_ly = 0;
  int16_t thumb_rx = 0;
  int16_t thumb_ry = 0;
};

inline bool operator==(const PadSample& a, const PadSample& b) {
  return a.buttons == b.buttons && a.left_trigger == b.left_trigger &&
         a.right_trigger == b.right_trigger && a.thumb_lx == b.thumb_lx &&
         a.thumb_ly == b.thumb_ly && a.thumb_rx == b.thumb_rx && a.thumb_ry == b.thumb_ry;
}

inline bool operator!=(const PadSample& a, const PadSample& b) { return !(a == b); }

inline bool IsNeutral(const PadSample& sample) {
  return sample == PadSample{};
}

struct Request {
  Command command = Command::kPing;
  uint8_t player = 0;
  PadSample sample{};
  uint32_t hold_ms = 0;
};

// Effective reading handed to the guest poll: the sample plus the driver's
// per-player packet number.
struct PadOutput {
  PadSample sample{};
  uint32_t packet = 0;
};

namespace detail {

inline uint16_t ReadLe16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}
inline uint32_t ReadLe32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
inline void WriteLe16(uint8_t* p, uint16_t v) {
  p[0] = static_cast<uint8_t>(v & 0xFF);
  p[1] = static_cast<uint8_t>((v >> 8) & 0xFF);
}
inline void WriteLe32(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>(v & 0xFF);
  p[1] = static_cast<uint8_t>((v >> 8) & 0xFF);
  p[2] = static_cast<uint8_t>((v >> 16) & 0xFF);
  p[3] = static_cast<uint8_t>((v >> 24) & 0xFF);
}
inline int16_t ReadLeI16(const uint8_t* p) {
  return static_cast<int16_t>(ReadLe16(p));
}
inline void WriteLeI16(uint8_t* p, int16_t v) { WriteLe16(p, static_cast<uint16_t>(v)); }

}  // namespace detail

// Decodes one fixed-size request frame. Returns kOk and fills `out`, or the
// first validation failure. Never reads past kRequestBytes and never trusts a
// length field: the caller passes exactly one frame.
inline Status DecodeRequest(const uint8_t* data, size_t length, Request& out) {
  if (data == nullptr || length != kRequestBytes) return Status::kBadLength;
  if (detail::ReadLe32(data + 0) != kMagic) return Status::kBadMagic;
  if (data[4] != kProtocolVersion) return Status::kBadVersion;
  const uint8_t raw_command = data[5];
  if (raw_command < static_cast<uint8_t>(Command::kSetState) ||
      raw_command > static_cast<uint8_t>(Command::kPing)) {
    return Status::kBadCommand;
  }
  const uint8_t player = data[6];
  if (player >= kPlayerCount) return Status::kBadPlayer;

  out.command = static_cast<Command>(raw_command);
  out.player = player;
  out.sample.buttons = detail::ReadLe16(data + 8);
  out.sample.left_trigger = data[10];
  out.sample.right_trigger = data[11];
  out.sample.thumb_lx = detail::ReadLeI16(data + 12);
  out.sample.thumb_ly = detail::ReadLeI16(data + 14);
  out.sample.thumb_rx = detail::ReadLeI16(data + 16);
  out.sample.thumb_ry = detail::ReadLeI16(data + 18);
  const uint32_t hold_ms = detail::ReadLe32(data + 20);
  out.hold_ms = hold_ms > kMaxHoldMs ? kMaxHoldMs : hold_ms;  // clamp
  return Status::kOk;
}

// Encodes the 24-byte little-endian request frame. Used by the CLI/tests to
// build messages; the driver only ever decodes them.
inline void EncodeRequest(const Request& request, uint8_t out[kRequestBytes]) {
  detail::WriteLe32(out + 0, kMagic);
  out[4] = kProtocolVersion;
  out[5] = static_cast<uint8_t>(request.command);
  out[6] = request.player;
  out[7] = 0;
  detail::WriteLe16(out + 8, request.sample.buttons);
  out[10] = request.sample.left_trigger;
  out[11] = request.sample.right_trigger;
  detail::WriteLeI16(out + 12, request.sample.thumb_lx);
  detail::WriteLeI16(out + 14, request.sample.thumb_ly);
  detail::WriteLeI16(out + 16, request.sample.thumb_rx);
  detail::WriteLeI16(out + 18, request.sample.thumb_ry);
  detail::WriteLe32(out + 20, request.hold_ms);
}

struct Response {
  Status status = Status::kOk;
  uint8_t player = 0;
  PadSample sample{};  // effective sample at the time the request was handled
  uint32_t packet = 0;
};

inline void EncodeResponse(const Response& response, uint8_t out[kResponseBytes]) {
  detail::WriteLe32(out + 0, kMagic);
  out[4] = kProtocolVersion;
  out[5] = static_cast<uint8_t>(response.status);
  out[6] = response.player;
  out[7] = 0;
  detail::WriteLe16(out + 8, response.sample.buttons);
  detail::WriteLe16(out + 10, 0);
  detail::WriteLe32(out + 12, response.packet);
}

inline Status DecodeResponse(const uint8_t* data, size_t length, Response& out) {
  if (data == nullptr || length != kResponseBytes) return Status::kBadLength;
  if (detail::ReadLe32(data + 0) != kMagic) return Status::kBadMagic;
  if (data[4] != kProtocolVersion) return Status::kBadVersion;
  out.status = static_cast<Status>(data[5]);
  out.player = data[6];
  out.sample = {};
  out.sample.buttons = detail::ReadLe16(data + 8);
  out.packet = detail::ReadLe32(data + 12);
  return Status::kOk;
}

// Latching pad state with an optional steady-clock TTL. Not synchronised; the
// server owns the mutex. `Read` advances the packet number only when the
// effective sample changes, so a guest polling an idle pad sees a stable packet.
class PadState {
 public:
  // Replace the whole sample. hold_ms == 0 means hold until released/cleared.
  void Set(const PadSample& sample, uint32_t hold_ms, uint64_t now_ms, uint64_t owner) {
    held_ = sample;
    SetExpiry(hold_ms, now_ms);
    owner_ = owner;
  }

  // OR buttons into the current sample, leaving axes/triggers untouched.
  void Press(uint16_t buttons, uint32_t hold_ms, uint64_t now_ms, uint64_t owner) {
    held_.buttons = static_cast<uint16_t>(held_.buttons | buttons);
    SetExpiry(hold_ms, now_ms);
    owner_ = owner;
  }

  // Clear buttons; buttons == 0 clears everything (including the TTL). An
  // explicit release always cancels the hold's TTL.
  void Release(uint16_t buttons) {
    if (buttons == 0) {
      held_ = PadSample{};
    } else {
      held_.buttons = static_cast<uint16_t>(held_.buttons & ~buttons);
    }
    has_expiry_ = false;
    expires_at_ms_ = 0;
  }

  // Drops any state the given connection set. Called when a client disconnects
  // so a dying client can never leave a button stuck down.
  void ClearOwner(uint64_t owner) {
    if (owner_ == owner) {
      held_ = PadSample{};
      has_expiry_ = false;
      expires_at_ms_ = 0;
      owner_ = 0;
    }
  }

  // Effective reading and packet number for the guest poll.
  PadOutput Read(uint64_t now_ms) {
    const PadSample effective = Effective(now_ms);
    if (!emitted_ || effective != last_) {
      ++packet_;
      last_ = effective;
      emitted_ = true;
    }
    return PadOutput{effective, packet_};
  }

  // Effective reading without advancing the packet number (used for replies).
  PadOutput Peek(uint64_t now_ms) { return PadOutput{Effective(now_ms), packet_}; }

 private:
  void SetExpiry(uint32_t hold_ms, uint64_t now_ms) {
    if (hold_ms == 0) {
      has_expiry_ = false;
      expires_at_ms_ = 0;
    } else {
      has_expiry_ = true;
      expires_at_ms_ = now_ms + hold_ms;
    }
  }

  // Applies TTL expiry: once the deadline passes the effective sample is
  // neutral and the held state is discarded so a later Set starts clean.
  PadSample Effective(uint64_t now_ms) {
    if (has_expiry_ && now_ms >= expires_at_ms_) {
      held_ = PadSample{};
      has_expiry_ = false;
      expires_at_ms_ = 0;
      owner_ = 0;
    }
    return held_;
  }

  PadSample held_{};
  PadSample last_{};
  uint64_t expires_at_ms_ = 0;
  uint64_t owner_ = 0;
  uint32_t packet_ = 0;
  bool has_expiry_ = false;
  bool emitted_ = false;
};

}  // namespace restreet::control
