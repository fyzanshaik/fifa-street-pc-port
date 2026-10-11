// Behavioral test for the macOS virtual-gamepad bridge.
//
// Drives the real protocol codec, pad state, device-assignment policy and the
// POSIX receiver server in src/control_{protocol.h,bridge_server.cpp} plus the
// fmt-free SDK-facing helpers (assignment/state). No ReXGlue runtime library,
// no GPU and no generated guest code are needed: the only extra include path is
// the SDK's public headers for rex::input::X_INPUT_STATE.
//
// It proves: slot 0 vs slot 1 routing and isolation, big-endian guest state,
// packet / TTL / release semantics, malformed protocol and player rejection,
// socket-collision handling, client-death cleanup and shutdown/unlink.
//
// Build/run: scripts/test-macos-virtual-input.sh

#include "../src/control_bridge_assignment.h"
#include "../src/control_bridge_server.h"
#include "../src/control_bridge_state.h"
#include "../src/control_protocol.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace ctl = restreet::control;
namespace rexi = rex::input;

namespace {

int g_failures = 0;

#define CHECK(cond)                                                         \
  do {                                                                      \
    if (!(cond)) {                                                          \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);           \
      ++g_failures;                                                         \
    }                                                                       \
  } while (0)

#define CHECK_EQ(a, b)                                                      \
  do {                                                                      \
    const auto _a = (a);                                                    \
    const auto _b = (b);                                                    \
    if (!(_a == _b)) {                                                      \
      std::printf("FAIL %s:%d: %s == %s\n", __FILE__, __LINE__, #a, #b);    \
      ++g_failures;                                                         \
    }                                                                       \
  } while (0)

std::string MakeTempDir() {
  std::vector<char> pattern = {'/', 't', 'm', 'p', '/', 'r', 'e', 's', 't', 'r',
                               'e', 'e', 't', '-', 'c', 't', 'l', '.', 'X', 'X',
                               'X', 'X', 'X', 'X', '\0'};
  char* dir = ::mkdtemp(pattern.data());
  return dir != nullptr ? std::string(dir) : std::string("/tmp");
}

class TestClient { public:
  explicit TestClient(const std::string& path) {
    fd_ = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd_ < 0) return;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
    if (::connect(fd_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
      ::close(fd_);
      fd_ = -1;
    }
  }
  ~TestClient() { Close(); }
  TestClient(const TestClient&) = delete;
  TestClient& operator=(const TestClient&) = delete;

  bool connected() const { return fd_ >= 0; }

  void Close() {
    if (fd_ >= 0) {
      ::close(fd_);
      fd_ = -1;
    }
  }

  bool SendRaw(const uint8_t* data, size_t size) {
    size_t sent = 0;
    while (sent < size) {
      const ssize_t n = ::send(fd_, data + sent, size - sent, 0);
      if (n <= 0) return false;
      sent += static_cast<size_t>(n);
    }
    return true;
  }

  bool Receive(ctl::Response& out) {
    uint8_t buffer[ctl::kResponseBytes];
    size_t received = 0;
    while (received < sizeof(buffer)) {
      const ssize_t n = ::recv(fd_, buffer + received, sizeof(buffer) - received, 0);
      if (n <= 0) return false;
      received += static_cast<size_t>(n);
    }
    ctl::DecodeResponse(buffer, sizeof(buffer), out);
    return true;
  }

  ctl::Status Send(const ctl::Request& request, ctl::Response* out = nullptr) {
    uint8_t buffer[ctl::kRequestBytes];
    ctl::EncodeRequest(request, buffer);
    if (!SendRaw(buffer, sizeof(buffer))) return ctl::Status::kBadLength;
    ctl::Response response;
    if (!Receive(response)) return ctl::Status::kBadLength;
    if (out != nullptr) *out = response;
    return response.status;
  }

 private:
  int fd_ = -1;
};

ctl::Request MakeRequest(ctl::Command command, uint8_t player) {
  ctl::Request request;
  request.command = command;
  request.player = player;
  return request;
}

bool WaitForNeutral(ctl::ControlBridgeServer& server, int player, int timeout_ms) {
  const int step = 10;
  for (int waited = 0; waited <= timeout_ms; waited += step) {
    if (ctl::IsNeutral(server.Read(player, ctl::ControlBridgeServer::NowMs()).sample)) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(step));
  }
  return false;
}

void TestProtocol() {
  ctl::Request request;
  request.command = ctl::Command::kPress;
  request.player = 1;
  request.sample.buttons = 0x1000;
  request.sample.left_trigger = 200;
  request.sample.thumb_lx = -12345;
  request.hold_ms = 500;

  uint8_t buffer[ctl::kRequestBytes];
  ctl::EncodeRequest(request, buffer);

  ctl::Request decoded;
  CHECK_EQ(static_cast<int>(ctl::DecodeRequest(buffer, sizeof(buffer), decoded)),
           static_cast<int>(ctl::Status::kOk));
  CHECK(decoded.command == ctl::Command::kPress);
  CHECK_EQ(decoded.player, 1);
  CHECK_EQ(decoded.sample.buttons, 0x1000);
  CHECK_EQ(decoded.sample.left_trigger, 200);
  CHECK_EQ(decoded.sample.thumb_lx, -12345);
  CHECK_EQ(decoded.hold_ms, 500u);

  uint8_t bad[ctl::kRequestBytes];

  std::memcpy(bad, buffer, sizeof(bad));
  bad[0] ^= 0xFF;
  CHECK(ctl::DecodeRequest(bad, sizeof(bad), decoded) == ctl::Status::kBadMagic);

  std::memcpy(bad, buffer, sizeof(bad));
  bad[4] = 99;
  CHECK(ctl::DecodeRequest(bad, sizeof(bad), decoded) == ctl::Status::kBadVersion);

  CHECK(ctl::DecodeRequest(buffer, sizeof(buffer) - 1, decoded) == ctl::Status::kBadLength);

  std::memcpy(bad, buffer, sizeof(bad));
  bad[5] = 99;
  CHECK(ctl::DecodeRequest(bad, sizeof(bad), decoded) == ctl::Status::kBadCommand);

  std::memcpy(bad, buffer, sizeof(bad));
  bad[6] = 2;
  CHECK(ctl::DecodeRequest(bad, sizeof(bad), decoded) == ctl::Status::kBadPlayer);
  bad[6] = 0xFF;
  CHECK(ctl::DecodeRequest(bad, sizeof(bad), decoded) == ctl::Status::kBadPlayer);

  // Oversized hold is clamped, not trusted.
  std::memcpy(bad, buffer, sizeof(bad));
  bad[20] = 0xFF;
  bad[21] = 0xFF;
  bad[22] = 0xFF;
  bad[23] = 0xFF;
  CHECK(ctl::DecodeRequest(bad, sizeof(bad), decoded) == ctl::Status::kOk);
  CHECK_EQ(decoded.hold_ms, ctl::kMaxHoldMs);

  // Full-range sticks survive the round trip unchanged.
  ctl::Request extremes;
  extremes.command = ctl::Command::kSetState;
  extremes.player = 0;
  extremes.sample.thumb_lx = INT16_MIN;
  extremes.sample.thumb_ly = INT16_MAX;
  extremes.sample.thumb_rx = 1;
  extremes.sample.thumb_ry = -1;
  ctl::EncodeRequest(extremes, buffer);
  CHECK(ctl::DecodeRequest(buffer, sizeof(buffer), decoded) == ctl::Status::kOk);
  CHECK_EQ(decoded.sample.thumb_lx, INT16_MIN);
  CHECK_EQ(decoded.sample.thumb_ly, INT16_MAX);
  CHECK_EQ(decoded.sample.thumb_rx, 1);
  CHECK_EQ(decoded.sample.thumb_ry, -1);

  ctl::Response response;
  response.status = ctl::Status::kPlayerNotBridged;
  response.player = 0;
  response.sample.buttons = 0xABCD;
  response.packet = 0x11223344;
  uint8_t encoded[ctl::kResponseBytes];
  ctl::EncodeResponse(response, encoded);
  ctl::Response decoded_response;
  CHECK(ctl::DecodeResponse(encoded, sizeof(encoded), decoded_response) == ctl::Status::kOk);
  CHECK(decoded_response.status == ctl::Status::kPlayerNotBridged);
  CHECK_EQ(decoded_response.player, 0);
  CHECK_EQ(decoded_response.sample.buttons, 0xABCD);
  CHECK_EQ(decoded_response.packet, 0x11223344u);
}

void TestModeNames() {
  // Unset, empty or unrecognised text keeps the historical isolated default.
  CHECK(ctl::ModeFromName(nullptr) == ctl::Mode::kAiAi);
  CHECK(ctl::ModeFromName("") == ctl::Mode::kAiAi);
  CHECK(ctl::ModeFromName("ai-ai") == ctl::Mode::kAiAi);
  CHECK(ctl::ModeFromName("human-ai") == ctl::Mode::kHumanAi);
  CHECK(ctl::ModeFromName("agent-cpu") == ctl::Mode::kAgentCpu);
  CHECK(ctl::ModeFromName("cpu") == ctl::Mode::kAiAi);
  CHECK(ctl::ModeFromName("AGENT-CPU") == ctl::Mode::kAiAi);
  CHECK(ctl::ModeFromName("agent-cpu ") == ctl::Mode::kAiAi);

  CHECK_EQ(std::string(ctl::ModeName(ctl::Mode::kAiAi)), std::string("ai-ai"));
  CHECK_EQ(std::string(ctl::ModeName(ctl::Mode::kHumanAi)), std::string("human-ai"));
  CHECK_EQ(std::string(ctl::ModeName(ctl::Mode::kAgentCpu)), std::string("agent-cpu"));

  // Presence: agent-cpu exposes exactly one pad, and it is pad 0.
  CHECK(ctl::PlayerBridged(ctl::Mode::kAgentCpu, 0));
  CHECK(!ctl::PlayerBridged(ctl::Mode::kAgentCpu, 1));
  CHECK(!ctl::PlayerBridged(ctl::Mode::kAgentCpu, 2));
  CHECK(ctl::PlayerBridged(ctl::Mode::kAiAi, 0));
  CHECK(ctl::PlayerBridged(ctl::Mode::kAiAi, 1));
  CHECK(!ctl::PlayerBridged(ctl::Mode::kHumanAi, 0));
  CHECK(ctl::PlayerBridged(ctl::Mode::kHumanAi, 1));
}

void TestPadState() {
  ctl::PadState pad;
  pad.Press(0x1000, 100, /*now_ms=*/0, /*owner=*/1);

  ctl::PadOutput output = pad.Read(0);
  CHECK_EQ(output.sample.buttons, 0x1000);
  CHECK_EQ(output.packet, 1u);

  output = pad.Read(50);
  CHECK_EQ(output.sample.buttons, 0x1000);
  CHECK_EQ(output.packet, 1u);  // unchanged sample -> stable packet

  output = pad.Read(100);  // TTL boundary: expired
  CHECK(ctl::IsNeutral(output.sample));
  CHECK_EQ(output.packet, 2u);

  output = pad.Read(200);
  CHECK(ctl::IsNeutral(output.sample));
  CHECK_EQ(output.packet, 2u);

  // Explicit release cancels the hold immediately.
  ctl::PadState released;
  released.Press(0x0010, 0, 0, 7);
  CHECK_EQ(released.Read(0).sample.buttons, 0x0010);
  released.Release(0x0010);
  CHECK(ctl::IsNeutral(released.Read(0).sample));

  // ClearOwner only clears the owning connection.
  ctl::PadState owned;
  owned.Set(ctl::PadSample{0xFFFF, 0, 0, 0, 0, 0, 0}, 0, 0, 42);
  owned.ClearOwner(99);
  CHECK_EQ(owned.Read(0).sample.buttons, 0xFFFF);
  owned.ClearOwner(42);
  CHECK(ctl::IsNeutral(owned.Read(0).sample));
}

void TestGuestStateEndianness() {
  ctl::PadOutput output;
  output.packet = 0x11223344;
  output.sample.buttons = 0x1000;
  output.sample.left_trigger = 0xAB;
  output.sample.right_trigger = 0x00;
  output.sample.thumb_lx = 0x0102;
  output.sample.thumb_ly = 0x0304;
  output.sample.thumb_rx = 0x0506;
  output.sample.thumb_ry = 0x0708;

  rexi::X_INPUT_STATE state{};
  ctl::WriteGuestState(output, &state);
  const uint8_t* bytes = reinterpret_cast<const uint8_t*>(&state);
  CHECK_EQ(static_cast<unsigned>(sizeof(state)), 16u);
  CHECK_EQ(bytes[0], 0x11);  // packet_number big-endian
  CHECK_EQ(bytes[1], 0x22);
  CHECK_EQ(bytes[2], 0x33);
  CHECK_EQ(bytes[3], 0x44);
  CHECK_EQ(bytes[4], 0x10);  // buttons big-endian
  CHECK_EQ(bytes[5], 0x00);
  CHECK_EQ(bytes[6], 0xAB);  // left trigger
  CHECK_EQ(bytes[7], 0x00);  // right trigger
  CHECK_EQ(bytes[8], 0x01);  // thumb_lx big-endian
  CHECK_EQ(bytes[9], 0x02);
  CHECK_EQ(bytes[10], 0x03);
  CHECK_EQ(bytes[11], 0x04);
  CHECK_EQ(bytes[12], 0x05);
  CHECK_EQ(bytes[13], 0x06);
  CHECK_EQ(bytes[14], 0x07);
  CHECK_EQ(bytes[15], 0x08);
}

void TestAssignmentRouting() {
  using rexi::DeviceId;
  rexi::DeviceInfo virtual0;
  virtual0.id = static_cast<DeviceId>(ctl::DeviceIdForPlayer(0));
  virtual0.synthetic = true;
  rexi::DeviceInfo virtual1;
  virtual1.id = static_cast<DeviceId>(ctl::DeviceIdForPlayer(1));
  virtual1.synthetic = true;
  rexi::DeviceInfo physical;
  physical.id = static_cast<DeviceId>(0x1234);
  physical.synthetic = false;
  physical.ordinal = 0;
  rexi::DeviceInfo keyboard;
  keyboard.id = static_cast<DeviceId>(0x4D4E4B00);
  keyboard.synthetic = true;

  std::vector<rexi::DeviceInfo> devices = {virtual0, virtual1, physical, keyboard};

  {
    ctl::VirtualPadAssignment assignment(ctl::Mode::kAiAi);
    assignment.OnDevicesChanged(devices);
    std::vector<DeviceId> user0;
    std::vector<DeviceId> user1;
    std::vector<DeviceId> user2;
    assignment.DevicesForUser(0, user0);
    assignment.DevicesForUser(1, user1);
    assignment.DevicesForUser(2, user2);
    CHECK_EQ(user0.size(), 1u);
    CHECK_EQ(user1.size(), 1u);
    CHECK(user0.size() == 1 && user0[0] == virtual0.id);
    CHECK(user1.size() == 1 && user1[0] == virtual1.id);
    CHECK(user2.empty());  // no physical or keyboard contamination
  }

  {
    ctl::VirtualPadAssignment assignment(ctl::Mode::kHumanAi);
    assignment.OnDevicesChanged(devices);
    std::vector<DeviceId> user0;
    std::vector<DeviceId> user1;
    assignment.DevicesForUser(0, user0);
    assignment.DevicesForUser(1, user1);
    // Physical + keyboard follow the SDK default on user 0; the virtual pad 1
    // feeds user 1; virtual pad 0 is dropped, not leaked to user 0.
    CHECK_EQ(user0.size(), 2u);
    CHECK_EQ(user1.size(), 1u);
    CHECK(user1.size() == 1 && user1[0] == virtual1.id);
    for (const auto& id : user0) {
      CHECK(id != virtual0.id);
      CHECK(id != virtual1.id);
    }
  }

  {
    ctl::VirtualPadAssignment assignment(ctl::Mode::kAgentCpu);
    assignment.OnDevicesChanged(devices);
    std::vector<DeviceId> user0;
    std::vector<DeviceId> user1;
    std::vector<DeviceId> user2;
    assignment.DevicesForUser(0, user0);
    assignment.DevicesForUser(1, user1);
    assignment.DevicesForUser(2, user2);
    // Only the agent's own pad on user 0: no virtual pad 1, and no foreign
    // physical/keyboard contamination of the CPU's side.
    CHECK_EQ(user0.size(), 1u);
    CHECK(user0.size() == 1 && user0[0] == virtual0.id);
    CHECK(user1.empty());
    CHECK(user2.empty());
  }
}

void TestServerLifecycle() {
  const std::string dir = MakeTempDir();
  const std::string path = dir + "/ctl.sock";

  ctl::ControlBridgeServer server;
  std::string error;
  CHECK(server.Start(path, ctl::Mode::kAiAi, &error) == ctl::ControlBridgeServer::StartResult::kOk);

  // Socket file present, ownable only by the owner.
  struct stat info {};
  CHECK(::stat(path.c_str(), &info) == 0);
  CHECK(S_ISSOCK(info.st_mode));
  CHECK_EQ(static_cast<int>(info.st_mode & 0777), 0600);

  // Slot isolation: player 0 press is invisible to player 1.
  {
    TestClient client(path);
    CHECK(client.connected());
    ctl::Request press = MakeRequest(ctl::Command::kPress, 0);
    press.sample.buttons = 0x0010;  // Start
    press.hold_ms = 1000;
    CHECK(client.Send(press) == ctl::Status::kOk);
    CHECK_EQ(server.Read(0, ctl::ControlBridgeServer::NowMs()).sample.buttons, 0x0010);
    CHECK(ctl::IsNeutral(server.Read(1, ctl::ControlBridgeServer::NowMs()).sample));

    // Player 1 gets its own press; the two pads stay independent.
    ctl::Request press1 = MakeRequest(ctl::Command::kPress, 1);
    press1.sample.buttons = 0x1000;  // A
    press1.hold_ms = 0;              // hold until released / disconnect
    CHECK(client.Send(press1) == ctl::Status::kOk);
    CHECK_EQ(server.Read(1, ctl::ControlBridgeServer::NowMs()).sample.buttons, 0x1000);
    CHECK_EQ(server.Read(0, ctl::ControlBridgeServer::NowMs()).sample.buttons, 0x0010);

    // Explicit release clears just that button.
    ctl::Request release = MakeRequest(ctl::Command::kRelease, 1);
    release.sample.buttons = 0x1000;
    CHECK(client.Send(release) == ctl::Status::kOk);
    CHECK(ctl::IsNeutral(server.Read(1, ctl::ControlBridgeServer::NowMs()).sample));
  }

  // Client died: every hold it set is cleared, so nothing is stuck.
  CHECK(WaitForNeutral(server, 0, 2000));
  CHECK(WaitForNeutral(server, 1, 2000));

  // TTL: a held press expires on its own against the steady clock.
  {
    TestClient client(path);
    ctl::Request press = MakeRequest(ctl::Command::kPress, 0);
    press.sample.buttons = 0x2000;  // B
    press.hold_ms = 60;
    CHECK(client.Send(press) == ctl::Status::kOk);
    const uint64_t now = ctl::ControlBridgeServer::NowMs();
    CHECK_EQ(server.Read(0, now).sample.buttons, 0x2000);
    CHECK(ctl::IsNeutral(server.Read(0, now + 10000).sample));  // far-future clock
  }
  WaitForNeutral(server, 0, 2000);

  // Malformed frames are rejected and leave the state untouched.
  {
    TestClient client(path);
    uint8_t good[ctl::kRequestBytes];
    ctl::Request ping = MakeRequest(ctl::Command::kPing, 0);
    ctl::EncodeRequest(ping, good);

    uint8_t bad[ctl::kRequestBytes];
    std::memcpy(bad, good, sizeof(bad));
    bad[0] = 0x00;  // corrupt magic
    ctl::Response response;
    CHECK(client.SendRaw(bad, sizeof(bad)));
    CHECK(client.Receive(response));
    CHECK(response.status == ctl::Status::kBadMagic);

    std::memcpy(bad, good, sizeof(bad));
    bad[6] = 7;  // impossible player
    CHECK(client.SendRaw(bad, sizeof(bad)));
    CHECK(client.Receive(response));
    CHECK(response.status == ctl::Status::kBadPlayer);

    std::memcpy(bad, good, sizeof(bad));
    bad[5] = 42;  // impossible command
    CHECK(client.SendRaw(bad, sizeof(bad)));
    CHECK(client.Receive(response));
    CHECK(response.status == ctl::Status::kBadCommand);

    // A valid request right after the garbage still works (stream stays in sync).
    ctl::Request press = MakeRequest(ctl::Command::kPress, 0);
    press.sample.buttons = 0x4000;  // X
    press.hold_ms = 0;
    CHECK(client.Send(press) == ctl::Status::kOk);
    CHECK_EQ(server.Read(0, ctl::ControlBridgeServer::NowMs()).sample.buttons, 0x4000);
    ctl::Request release = MakeRequest(ctl::Command::kRelease, 0);
    release.sample.buttons = 0;
    CHECK(client.Send(release) == ctl::Status::kOk);
  }

  // A live bridge owns the path: a second Start must fail, not unlink it.
  {
    ctl::ControlBridgeServer second;
    std::string second_error;
    CHECK(second.Start(path, ctl::Mode::kAiAi, &second_error) ==
          ctl::ControlBridgeServer::StartResult::kOccupiedByBridge);
    CHECK(::stat(path.c_str(), &info) == 0);  // first socket untouched
  }

  server.Stop();
  CHECK(::stat(path.c_str(), &info) != 0);  // unlinked on shutdown
  server.Stop();                            // idempotent

  // Path now free again.
  {
    ctl::ControlBridgeServer third;
    CHECK(third.Start(path, ctl::Mode::kHumanAi, &error) ==
          ctl::ControlBridgeServer::StartResult::kOk);
    CHECK(third.Read(1, ctl::ControlBridgeServer::NowMs()).sample.buttons == 0);
    third.Stop();
  }

  // A regular file at the path is never deleted and Start fails explicitly.
  {
    const std::string file_path = dir + "/not-a-socket";
    FILE* file = std::fopen(file_path.c_str(), "w");
    CHECK(file != nullptr);
    if (file != nullptr) std::fclose(file);
    ctl::ControlBridgeServer blocked;
    CHECK(blocked.Start(file_path, ctl::Mode::kAiAi, &error) ==
          ctl::ControlBridgeServer::StartResult::kOccupiedByFile);
    CHECK(::stat(file_path.c_str(), &info) == 0);
    ::unlink(file_path.c_str());
  }

  // Reject bad paths before touching the filesystem.
  {
    ctl::ControlBridgeServer relative;
    CHECK(relative.Start("relative.sock", ctl::Mode::kAiAi, &error) ==
          ctl::ControlBridgeServer::StartResult::kNotAbsolute);
    ctl::ControlBridgeServer long_path;
    const std::string too_long = "/tmp/" + std::string(200, 'x');
    CHECK(long_path.Start(too_long, ctl::Mode::kAiAi, &error) ==
          ctl::ControlBridgeServer::StartResult::kPathTooLong);
  }

  ::rmdir(dir.c_str());
}

void TestHumanAiMode() {
  const std::string dir = MakeTempDir();
  const std::string path = dir + "/ctl.sock";

  ctl::ControlBridgeServer server;
  std::string error;
  CHECK(server.Start(path, ctl::Mode::kHumanAi, &error) ==
        ctl::ControlBridgeServer::StartResult::kOk);

  TestClient client(path);
  CHECK(client.connected());
  // Player 0 is not bridged in human-ai: an explicit request is refused, and
  // the human's physical slot is never written by the bridge.
  ctl::Request press0 = MakeRequest(ctl::Command::kPress, 0);
  press0.sample.buttons = 0x0010;
  press0.hold_ms = 1000;
  ctl::Response response;
  CHECK(client.Send(press0, &response) == ctl::Status::kPlayerNotBridged);
  CHECK(ctl::IsNeutral(server.Read(0, ctl::ControlBridgeServer::NowMs()).sample));

  // Player 1 works.
  ctl::Request press1 = MakeRequest(ctl::Command::kPress, 1);
  press1.sample.buttons = 0x0010;
  press1.hold_ms = 1000;
  CHECK(client.Send(press1) == ctl::Status::kOk);
  CHECK_EQ(server.Read(1, ctl::ControlBridgeServer::NowMs()).sample.buttons, 0x0010);

  client.Close();
  server.Stop();
  ::rmdir(dir.c_str());
}

void TestAgentCpuMode() {
  const std::string dir = MakeTempDir();
  const std::string path = dir + "/ctl.sock";

  ctl::ControlBridgeServer server;
  std::string error;
  CHECK(server.Start(path, ctl::Mode::kAgentCpu, &error) ==
        ctl::ControlBridgeServer::StartResult::kOk);
  CHECK(server.mode() == ctl::Mode::kAgentCpu);

  TestClient client(path);
  CHECK(client.connected());

  // The one bridged slot accepts a full bounded sample: buttons, triggers and
  // all four stick axes survive the socket round trip unchanged.
  ctl::Request state = MakeRequest(ctl::Command::kSetState, 0);
  state.sample.buttons = 0x1000 | 0x4000;  // A + X
  state.sample.left_trigger = 0x7F;
  state.sample.right_trigger = 0xFF;
  state.sample.thumb_lx = 32767;
  state.sample.thumb_ly = -32768;
  state.sample.thumb_rx = 12345;
  state.sample.thumb_ry = -12345;
  state.hold_ms = 500;
  ctl::Response response;
  CHECK(client.Send(state, &response) == ctl::Status::kOk);
  CHECK_EQ(response.sample.buttons, 0x5000);
  ctl::PadSample read = server.Read(0, ctl::ControlBridgeServer::NowMs()).sample;
  CHECK_EQ(read.buttons, 0x5000);
  CHECK_EQ(read.left_trigger, 0x7F);
  CHECK_EQ(read.right_trigger, 0xFF);
  CHECK_EQ(read.thumb_lx, 32767);
  CHECK_EQ(read.thumb_ly, -32768);
  CHECK_EQ(read.thumb_rx, 12345);
  CHECK_EQ(read.thumb_ry, -12345);

  // The unavailable second slot is rejected, and the refusal does not perturb
  // the active slot or leave any state on the rejected one.
  ctl::Request press1 = MakeRequest(ctl::Command::kPress, 1);
  press1.sample.buttons = 0x0010;
  press1.hold_ms = 1000;
  CHECK(client.Send(press1, &response) == ctl::Status::kPlayerNotBridged);
  CHECK_EQ(response.player, 1);
  CHECK(ctl::IsNeutral(server.Read(1, ctl::ControlBridgeServer::NowMs()).sample));
  CHECK_EQ(server.Read(0, ctl::ControlBridgeServer::NowMs()).sample.buttons, 0x5000);

  // An explicit release on the active slot clears it immediately.
  ctl::Request release = MakeRequest(ctl::Command::kRelease, 0);
  release.sample.buttons = 0;
  CHECK(client.Send(release, &response) == ctl::Status::kOk);
  CHECK(ctl::IsNeutral(server.Read(0, ctl::ControlBridgeServer::NowMs()).sample));

  // Disconnecting still releases a held command (connection-scoped lifetime).
  ctl::Request held = MakeRequest(ctl::Command::kPress, 0);
  held.sample.buttons = 0x2000;  // B
  held.hold_ms = 0;              // hold until released / disconnect
  CHECK(client.Send(held) == ctl::Status::kOk);
  CHECK_EQ(server.Read(0, ctl::ControlBridgeServer::NowMs()).sample.buttons, 0x2000);
  client.Close();
  CHECK(WaitForNeutral(server, 0, 2000));
  CHECK(ctl::IsNeutral(server.Read(1, ctl::ControlBridgeServer::NowMs()).sample));

  server.Stop();
  ::rmdir(dir.c_str());
}

}  // namespace

int main() {
  TestProtocol();
  TestModeNames();
  TestPadState();
  TestGuestStateEndianness();
  TestAssignmentRouting();
  TestServerLifecycle();
  TestHumanAiMode();
  TestAgentCpuMode();

  if (g_failures == 0) {
    std::printf("All virtual-gamepad bridge behavioral tests passed\n");
    return 0;
  }
  std::printf("%d check(s) failed\n", g_failures);
  return 1;
}
