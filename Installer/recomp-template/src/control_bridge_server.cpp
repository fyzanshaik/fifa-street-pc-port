// See control_bridge_server.h. POSIX only; compiled on Apple.

#include "control_bridge_server.h"

#include <cerrno>
#include <chrono>
#include <cstring>

#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <filesystem>
#include <string>
#include <vector>

namespace restreet::control {

namespace {

constexpr int kPollTimeoutMs = 100;

// Probes whether something is accepting connections at `path`. A refused connect
// or a failed one means the socket file is stale; a successful connect means a
// live bridge already owns it.
bool SocketIsLive(const std::string& path) {
  const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return false;
  }
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);

  const int flags = ::fcntl(fd, F_GETFL, 0);
  ::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  bool live = false;
  if (::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0) {
    live = true;
  } else if (errno == EINPROGRESS) {
    pollfd probe{fd, POLLOUT, 0};
    if (::poll(&probe, 1, 100) > 0) {
      int socket_error = 0;
      socklen_t length = sizeof(socket_error);
      if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error, &length) == 0) {
        live = socket_error == 0;
      }
    }
  }
  ::close(fd);
  return live;
}

bool SendAll(int fd, const uint8_t* data, size_t size) {
  size_t sent = 0;
  while (sent < size) {
    const ssize_t n = ::send(fd, data + sent, size - sent, MSG_NOSIGNAL);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    if (n == 0) {
      return false;
    }
    sent += static_cast<size_t>(n);
  }
  return true;
}

}  // namespace

const char* StartResultName(ControlBridgeServer::StartResult result) {
  switch (result) {
    case ControlBridgeServer::StartResult::kOk: return "ok";
    case ControlBridgeServer::StartResult::kNotAbsolute: return "socket path must be absolute";
    case ControlBridgeServer::StartResult::kPathTooLong: return "socket path too long";
    case ControlBridgeServer::StartResult::kParentFailed: return "cannot create socket directory";
    case ControlBridgeServer::StartResult::kOccupiedByFile: return "path exists and is not a socket";
    case ControlBridgeServer::StartResult::kOccupiedByBridge: return "another bridge is listening";
    case ControlBridgeServer::StartResult::kSocketFailed: return "socket() failed";
    case ControlBridgeServer::StartResult::kBindFailed: return "bind() failed";
    case ControlBridgeServer::StartResult::kListenFailed: return "listen() failed";
    case ControlBridgeServer::StartResult::kThreadFailed: return "receiver thread failed";
  }
  return "unknown";
}

ControlBridgeServer::~ControlBridgeServer() { Stop(); }

uint64_t ControlBridgeServer::NowMs() {
  return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                   std::chrono::steady_clock::now().time_since_epoch())
                                   .count());
}

ControlBridgeServer::StartResult ControlBridgeServer::Start(const std::string& socket_path,
                                                            Mode mode, std::string* error) {
  const auto fail = [error](StartResult result) {
    if (error != nullptr) {
      *error = StartResultName(result);
    }
    return result;
  };

  if (running_.load(std::memory_order_acquire)) {
    return fail(StartResult::kBindFailed);
  }
  if (socket_path.empty() || socket_path[0] != '/') {
    return fail(StartResult::kNotAbsolute);
  }
  if (socket_path.size() >= sizeof(sockaddr_un::sun_path)) {
    return fail(StartResult::kPathTooLong);
  }

  // Owner-only directory: create it 0700 when missing, never re-permission an
  // existing one.
  const std::filesystem::path path(socket_path);
  const std::filesystem::path parent = path.parent_path();
  if (!parent.empty()) {
    std::error_code ec;
    const bool existed = std::filesystem::exists(parent, ec);
    std::filesystem::create_directories(parent, ec);
    if (ec) {
      return fail(StartResult::kParentFailed);
    }
    if (!existed) {
      ::chmod(parent.c_str(), 0700);
    }
  }

  // Refuse to clobber a user file or a live bridge; a stale socket is removed.
  struct stat info {};
  if (::lstat(socket_path.c_str(), &info) == 0) {
    if (!S_ISSOCK(info.st_mode)) {
      return fail(StartResult::kOccupiedByFile);
    }
    if (SocketIsLive(socket_path)) {
      return fail(StartResult::kOccupiedByBridge);
    }
    if (::unlink(socket_path.c_str()) != 0) {
      return fail(StartResult::kBindFailed);
    }
  } else if (errno != ENOENT) {
    return fail(StartResult::kBindFailed);
  }

  const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return fail(StartResult::kSocketFailed);
  }
  const int enable = 1;
  ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enable, sizeof(enable));

  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::strncpy(address.sun_path, socket_path.c_str(), sizeof(address.sun_path) - 1);
  if (::bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
    ::close(fd);
    return fail(StartResult::kBindFailed);
  }
  ::chmod(socket_path.c_str(), 0600);  // defeat the umask

  if (::listen(fd, 1) != 0) {
    ::close(fd);
    ::unlink(socket_path.c_str());
    return fail(StartResult::kListenFailed);
  }

  socket_path_ = socket_path;
  mode_ = mode;
  listen_fd_ = fd;
  owns_socket_ = true;
  running_.store(true, std::memory_order_release);
  receiver_ = std::thread([this] { ReceiverLoop(); });
  if (!receiver_.joinable()) {
    running_.store(false, std::memory_order_release);
    ::close(fd);
    ::unlink(socket_path.c_str());
    listen_fd_ = -1;
    owns_socket_ = false;
    return fail(StartResult::kThreadFailed);
  }
  return StartResult::kOk;
}

void ControlBridgeServer::Stop() {
  if (running_.exchange(false, std::memory_order_acq_rel) || receiver_.joinable()) {
    if (receiver_.joinable()) {
      receiver_.join();
    }
  }
  if (listen_fd_ >= 0) {
    ::close(listen_fd_);
    listen_fd_ = -1;
  }
  // Unlink only the socket this server bound; a failed Start never set this, so
  // a user file or another bridge's socket is never removed.
  if (owns_socket_) {
    ::unlink(socket_path_.c_str());
    owns_socket_ = false;
  }
  std::lock_guard lock(mutex_);
  for (auto& pad : pads_) {
    pad.Release(0);  // drop every hold; a stopped bridge reads neutral
  }
}

void ControlBridgeServer::ReceiverLoop() {
  while (running_.load(std::memory_order_acquire)) {
    pollfd listen_poll{listen_fd_, POLLIN, 0};
    const int ready = ::poll(&listen_poll, 1, kPollTimeoutMs);
    if (ready <= 0) {
      continue;
    }
    if ((listen_poll.revents & POLLIN) == 0) {
      continue;
    }
    const int connection = ::accept(listen_fd_, nullptr, nullptr);
    if (connection < 0) {
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
        continue;
      }
      break;
    }
    const int enable = 1;
    ::setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enable, sizeof(enable));
    HandleClient(connection, next_connection_++);
    ::close(connection);
  }
}

void ControlBridgeServer::HandleClient(int fd, uint64_t connection_id) {
  std::vector<uint8_t> buffer;
  uint8_t chunk[512];
  while (running_.load(std::memory_order_acquire)) {
    pollfd client_poll{fd, POLLIN, 0};
    const int ready = ::poll(&client_poll, 1, kPollTimeoutMs);
    if (ready == 0) {
      continue;
    }
    if (ready < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }
    const ssize_t n = ::recv(fd, chunk, sizeof(chunk), 0);
    if (n == 0) {
      break;  // client closed
    }
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }
    buffer.insert(buffer.end(), chunk, chunk + n);

    bool connection_lost = false;
    while (buffer.size() >= kRequestBytes) {
      Request request;
      const Status decoded = DecodeRequest(buffer.data(), kRequestBytes, request);
      // Always consume exactly one frame so a malformed frame cannot desync the
      // stream into reading a later frame at the wrong offset.
      buffer.erase(buffer.begin(), buffer.begin() + kRequestBytes);

      const Response response = HandleRequest(request, decoded, connection_id);
      uint8_t encoded[kResponseBytes];
      EncodeResponse(response, encoded);
      if (!SendAll(fd, encoded, kResponseBytes)) {
        connection_lost = true;
        break;
      }
    }
    if (connection_lost) {
      break;
    }
  }

  // A dying client must not leave a button stuck: drop everything it set.
  std::lock_guard lock(mutex_);
  for (auto& pad : pads_) {
    pad.ClearOwner(connection_id);
  }
}

Response ControlBridgeServer::HandleRequest(const Request& request, Status decode_status,
                                            uint64_t connection_id) {
  Response response;
  response.player = request.player;
  if (decode_status != Status::kOk) {
    response.status = decode_status;
    return response;
  }
  if (!PlayerBridged(mode_, request.player)) {
    response.status = Status::kPlayerNotBridged;
    return response;
  }

  const uint64_t now_ms = NowMs();
  std::lock_guard lock(mutex_);
  PadState& pad = pads_[request.player];
  switch (request.command) {
    case Command::kSetState:
      pad.Set(request.sample, request.hold_ms, now_ms, connection_id);
      break;
    case Command::kPress:
      pad.Press(request.sample.buttons, request.hold_ms, now_ms, connection_id);
      break;
    case Command::kRelease:
      pad.Release(request.sample.buttons);
      break;
    case Command::kPing:
      break;
  }
  const PadOutput effective = pad.Peek(now_ms);
  response.status = Status::kOk;
  response.sample = effective.sample;
  response.packet = effective.packet;
  return response;
}

PadOutput ControlBridgeServer::Read(int player, uint64_t now_ms) {
  std::lock_guard lock(mutex_);
  return pads_[player].Read(now_ms);
}

}  // namespace restreet::control
