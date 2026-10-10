// Opt-in virtual-gamepad control bridge for AI evaluation.
//
// Owns a single owner-only Unix-domain socket and a receiver thread. A local
// client (the Python CLI, or a later agent) sends small fixed-layout messages
// that latch a virtual pad's state; the guest thread polls the state through
// ControlBridgeServer::Read without ever touching the socket, so a slow or dead
// client cannot stall the guest.
//
// Safety properties, all covered by scripts/test-macos-virtual-input.sh:
//   * no TCP, no network, no authentication change - a local socket only;
//   * the socket file is 0600 and lives under an owner-only directory;
//   * an existing regular file or a live bridge socket is never unlinked; Start
//     fails explicitly instead;
//   * a client that disconnects has every hold it set cleared, so a crash
//     cannot leave a button stuck down; a hold TTL is the second line of defence;
//   * Stop() joins the receiver and unlinks only the socket this server bound.
//
// Runtime-free: POSIX + the control protocol only, so it compiles and unit-tests
// without the ReXGlue SDK.

#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

#include "control_protocol.h"

namespace restreet::control {

class ControlBridgeServer {
 public:
  enum class StartResult {
    kOk,
    kNotAbsolute,
    kPathTooLong,
    kParentFailed,
    kOccupiedByFile,
    kOccupiedByBridge,
    kSocketFailed,
    kBindFailed,
    kListenFailed,
    kThreadFailed,
  };

  ControlBridgeServer() = default;
  ~ControlBridgeServer();
  ControlBridgeServer(const ControlBridgeServer&) = delete;
  ControlBridgeServer& operator=(const ControlBridgeServer&) = delete;

  // Binds `socket_path` and starts the receiver. On failure returns a reason and
  // leaves no socket behind. Must be called before the guest starts polling.
  StartResult Start(const std::string& socket_path, Mode mode, std::string* error);
  // Joins the receiver and unlinks the socket this server created. Idempotent.
  void Stop();

  bool running() const { return running_.load(std::memory_order_acquire); }
  Mode mode() const { return mode_; }
  const std::string& socket_path() const { return socket_path_; }

  // Guest-thread poll: copies the effective sample for `player`. Never blocks on
  // the socket; the lock is held only for the state copy.
  PadOutput Read(int player, uint64_t now_ms);

  // Monotonic millisecond clock shared by the state TTLs and the poll.
  static uint64_t NowMs();

 private:
  void ReceiverLoop();
  void HandleClient(int fd, uint64_t connection_id);
  Response HandleRequest(const Request& request, Status decode_status, uint64_t connection_id);

  std::string socket_path_;
  Mode mode_ = Mode::kAiAi;
  std::atomic<bool> running_{false};
  int listen_fd_ = -1;
  bool owns_socket_ = false;
  uint64_t next_connection_ = 1;
  std::thread receiver_;

  mutable std::mutex mutex_;
  PadState pads_[kPlayerCount];
};

const char* StartResultName(ControlBridgeServer::StartResult result);

}  // namespace restreet::control
