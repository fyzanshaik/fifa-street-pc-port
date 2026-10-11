// Focused offline fixture: drive the pinned runtime's rex::filesystem
// HostPathDevice against a synthetic tree, so a profile's directory layout can
// be classified without the game.
//
// Links the installed/pinned runtime dylib (build/macos/out/librexruntime.dylib)
// and uses the SDK headers only. It reports how the runtime sees each top-level
// entry and then emulates VirtualFileSystem::OpenFile for a nested guest path:
// resolve the parent directory, then take the leaf with GetChild. The pinned
// runtime classifies entries from dirent d_type, so a symlinked directory is
// reported as a file, is never recursed into, and the leaf lookup fails.
//
// Usage: macos_credit_vfs_probe <root> <guest/path>
// Exit 0 when the OpenFile emulation succeeds, 1 when the leaf is missing.
#include <cstdio>
#include <string>

#include <rex/filesystem.h>
#include <rex/filesystem/devices/host_path_device.h>

namespace fs = rex::filesystem;

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <root> <guest/path>\n", argv[0]);
    return 2;
  }
  std::filesystem::path root = argv[1];
  std::string path = argv[2];

  for (const auto& info : fs::ListFiles(root)) {
    std::printf("entry %s %s %llu\n", rex::path_to_utf8(info.name).c_str(),
                info.type == fs::FileInfo::Type::kDirectory ? "dir" : "file",
                static_cast<unsigned long long>(info.total_size));
  }

  fs::HostPathDevice device("game:", root, true, false);
  if (!device.Initialize()) {
    std::printf("INIT FAIL\n");
    return 2;
  }
  std::printf("FULL_RESOLVE %s\n", device.ResolvePath(path) ? "OK" : "NULL");

  auto slash = path.find_last_of("/\\");
  if (slash == std::string::npos) {
    return 0;
  }
  std::string base = path.substr(0, slash);
  std::string leaf = path.substr(slash + 1);

  // A fresh device, so an earlier full ResolvePath cannot populate the tree.
  fs::HostPathDevice fresh("game:", root, true, false);
  if (!fresh.Initialize()) {
    std::printf("INIT FAIL\n");
    return 2;
  }
  fs::Entry* parent = fresh.ResolvePath(base);
  std::printf("OPENFILE_BASE %s\n", parent ? "OK" : "NULL");
  if (!parent) {
    std::printf("OPENFILE_LEAF NULL\n");
    return 1;
  }
  fs::Entry* child = parent->GetChild(leaf);
  std::printf("OPENFILE_LEAF %s\n", child ? "OK" : "NULL");
  return child ? 0 : 1;
}
