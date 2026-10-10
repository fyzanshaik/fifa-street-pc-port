// Exercise the real PPC decoder and code writer with a synthetic instruction
// fixture. No game assets, runtime window, devices or injected game input.
#include <array>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

#include <rex/codegen/codegen_context.h>
#include <rex/codegen/codegen_writer.h>
#include <rex/codegen/test_support.h>

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  namespace fs = std::filesystem;
  using namespace rex::codegen;
  const fs::path root = fs::absolute(argv[1]);
  if (fs::exists(root / "generated")) {
    std::cerr << "Refusing to overwrite an existing generated fixture\n";
    return 2;
  }
  fs::create_directories(root);
  constexpr uint32_t base = 0x82000000;
  // sync, lwsync, eieio, nop; each is followed by blr. PPC words are BE.
  constexpr std::array<uint32_t, 4> words = {
      0x7C0004AC, 0x7C2004AC, 0x7C0006AC, 0x60000000};
  std::vector<uint8_t> data;
  for (const auto word : words) {
    for (const auto instruction : {word, 0x4E800020u}) {
      for (int shift = 24; shift >= 0; shift -= 8)
        data.push_back(static_cast<uint8_t>(instruction >> shift));
    }
  }
  TestModule module;
  module.Load(base, data.data(), data.size());
  RecompilerConfig config;
  config.projectName = "barriers";
  config.outDirectoryPath = "generated";
  auto ctx = CodegenContext::Create(BinaryView::fromModule(module), std::move(config));
  ctx.setConfigDir(root);
  ctx.analysisState().format = "xex";
  ctx.analysisState().loadAddress = base;
  ctx.analysisState().entryPoint = base;
  ctx.analysisState().imageSize = data.size();
  for (uint32_t i = 0; i < words.size(); ++i) {
    const uint32_t address = base + i * 8;
    auto* node = ctx.graph.addFunction(address, 8, FunctionAuthority::DISCOVERED, true);
    if (!node) return 2;
    node->discover({{address, 8}}, {}, {});
    node->seal();
  }
  CodegenWriter writer(ctx);
  if (!writer.write(true)) return 2;
  std::string output;
  for (const auto& entry : fs::directory_iterator(root / "generated")) {
    if (entry.path().filename().string().starts_with("barriers_recomp.") &&
        entry.path().extension() == ".cpp") {
      std::ifstream file(entry.path());
      output.append(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
    }
  }
  int failures = 0;
  const auto check = [&](bool pass, const char* name) {
    std::cout << (pass ? "PASS " : "FAIL ") << name << '\n';
    failures += !pass;
  };
  const auto body = [&](const char* instruction) {
    const auto start = output.find(std::string("// ") + instruction + " ");
    if (start == std::string::npos) return std::string{};
    const auto end = output.find("// blr", start);
    return output.substr(start, end == std::string::npos ? end : end - start);
  };
  check(!output.empty() && !body("nop").empty(), "real decoder/writer produced fixture");
  check(body("sync").find("std::atomic_thread_fence(std::memory_order_seq_cst)") !=
            std::string::npos, "sync retains full memory fence");
  check(body("lwsync").find("std::atomic_thread_fence(std::memory_order_acq_rel)") !=
            std::string::npos, "lwsync retains acquire/release memory fence");
  check(body("eieio").find("std::atomic_thread_fence(std::memory_order_seq_cst)") !=
            std::string::npos, "eieio retains conservative I/O fence");
  check(body("nop").find("atomic_thread_fence") == std::string::npos,
        "nop remains a no-op");
  std::cout << "Generated fixture: " << root / "generated" << '\n';
  std::cout << "Checks: " << 5 - failures << "/5 passed\n";
  return failures ? 1 : 0;
}
