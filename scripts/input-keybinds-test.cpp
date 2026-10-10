// input-keybinds-test.cpp
//
// Focused, source-controlled regression test for the macOS keyboard-to-controller
// chain that the FIFA Street MnK driver depends on:
//
//     SDL scancode --TranslateSDLScancode--> VirtualKey --ParseVirtualKey--> bind
//
// It links the input-diagnostics runtime and reads the *real* default
// controller keybind strings from the exported REXCVAR_DEFINE_STRING storages
// (FLAGS_keybind_*_storage_()). That makes the test read the shipping defaults
// instead of a hardcoded copy, so a default that no longer parses, or a token
// whose SDL scancode no longer translates to the same VirtualKey, fails here.
//
// It links only the SDK runtime; no window, no GPU, no guest, no game launch.
// The runner materialises <rex/input/input_diagnostics.h> from the diagnostic
// patch, since the default SDK stack does not carry it.
//
// Usage:
//   scripts/test-macos-input-diagnostics.sh [path/to/runtime-dir]
//
// Exit 0 if every check passes, 1 otherwise.

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include <SDL3/SDL_scancode.h>

#include <rex/input/input_diagnostics.h>
#include <rex/ui/keybinds.h>
#include <rex/ui/sdl_virtual_key.h>
#include <rex/ui/virtual_key.h>

// --- Exported default-storage accessors (REXCVAR_DEFINE_STRING) --------------
// Defined at global scope in src/input/mnk/mnk_input_driver.cpp.
std::string& FLAGS_keybind_a_storage_();
std::string& FLAGS_keybind_b_storage_();
std::string& FLAGS_keybind_x_storage_();
std::string& FLAGS_keybind_y_storage_();
std::string& FLAGS_keybind_left_trigger_storage_();
std::string& FLAGS_keybind_right_trigger_storage_();
std::string& FLAGS_keybind_left_shoulder_storage_();
std::string& FLAGS_keybind_right_shoulder_storage_();
std::string& FLAGS_keybind_lstick_up_storage_();
std::string& FLAGS_keybind_lstick_down_storage_();
std::string& FLAGS_keybind_lstick_left_storage_();
std::string& FLAGS_keybind_lstick_right_storage_();
std::string& FLAGS_keybind_lstick_press_storage_();
std::string& FLAGS_keybind_rstick_up_storage_();
std::string& FLAGS_keybind_rstick_down_storage_();
std::string& FLAGS_keybind_rstick_left_storage_();
std::string& FLAGS_keybind_rstick_right_storage_();
std::string& FLAGS_keybind_rstick_press_storage_();
std::string& FLAGS_keybind_dpad_up_storage_();
std::string& FLAGS_keybind_dpad_down_storage_();
std::string& FLAGS_keybind_dpad_left_storage_();
std::string& FLAGS_keybind_dpad_right_storage_();
std::string& FLAGS_keybind_back_storage_();
std::string& FLAGS_keybind_start_storage_();
std::string& FLAGS_keybind_guide_storage_();

namespace {

using rex::ui::ParseVirtualKey;
using rex::ui::TranslateSDLScancode;
using rex::ui::VirtualKey;

int g_failures = 0;

void Report(bool ok, const char* what) {
  if (!ok) {
    ++g_failures;
    std::printf("FAIL %s\n", what);
  }
}

std::string_view Trim(std::string_view s) {
  while (!s.empty() && s.front() == ' ') s.remove_prefix(1);
  while (!s.empty() && s.back() == ' ') s.remove_suffix(1);
  return s;
}

// Strips leading "Shift+"/"Ctrl+"/"Alt+" prefixes, mirroring the MnK bind
// parser's modifier handling, and returns the bare key token.
std::string_view StripModifiers(std::string_view token) {
  for (;;) {
    size_t plus = token.find('+');
    if (plus == std::string_view::npos || plus == 0) break;
    std::string_view head = token.substr(0, plus);
    if (head == "Shift" || head == "Ctrl" || head == "Control" || head == "Alt") {
      token.remove_prefix(plus + 1);
      continue;
    }
    break;
  }
  return token;
}

struct ScanFor {
  const char* token;
  SDL_Scancode scancode;
};

// Every bare (modifier-stripped) token used by the default controller binds.
constexpr ScanFor kScancodeForToken[] = {
    {"Semicolon", SDL_SCANCODE_SEMICOLON}, {"Space", SDL_SCANCODE_SPACE},
    {"Quote", SDL_SCANCODE_APOSTROPHE},    {"Backspace", SDL_SCANCODE_BACKSPACE},
    {"L", SDL_SCANCODE_L},                 {"P", SDL_SCANCODE_P},
    {"Q", SDL_SCANCODE_Q},                 {"I", SDL_SCANCODE_I},
    {"E", SDL_SCANCODE_E},                 {"O", SDL_SCANCODE_O},
    {"1", SDL_SCANCODE_1},                 {"3", SDL_SCANCODE_3},
    {"W", SDL_SCANCODE_W},                 {"S", SDL_SCANCODE_S},
    {"A", SDL_SCANCODE_A},                 {"D", SDL_SCANCODE_D},
    {"F", SDL_SCANCODE_F},                 {"Up", SDL_SCANCODE_UP},
    {"Down", SDL_SCANCODE_DOWN},           {"Left", SDL_SCANCODE_LEFT},
    {"Right", SDL_SCANCODE_RIGHT},         {"K", SDL_SCANCODE_K},
    {"Z", SDL_SCANCODE_Z},                 {"Tab", SDL_SCANCODE_TAB},
    {"X", SDL_SCANCODE_X},                 {"Return", SDL_SCANCODE_RETURN},
};

SDL_Scancode ScancodeFor(std::string_view token) {
  for (const auto& entry : kScancodeForToken) {
    if (token == entry.token) return entry.scancode;
  }
  return SDL_SCANCODE_UNKNOWN;
}

std::vector<std::string> SplitBinds(std::string_view value) {
  std::vector<std::string> out;
  std::string_view rest = value;
  while (!rest.empty()) {
    size_t comma = rest.find(',');
    std::string_view token = rest.substr(0, comma);
    if (comma == std::string_view::npos) {
      rest = std::string_view();
    } else {
      rest.remove_prefix(comma + 1);
    }
    out.emplace_back(Trim(token));
  }
  return out;
}

int g_bind_tokens = 0;

// For a bind cvar value: every token must parse, and every bare token with a
// known physical key must map SDL scancode -> the same VirtualKey.
void CheckBind(const char* name, std::string_view value) {
  for (std::string& token_owned : SplitBinds(value)) {
    std::string_view token = token_owned;
    if (token.empty()) continue;  // e.g. an unbound guide button.
    ++g_bind_tokens;

    std::string_view bare = StripModifiers(token);
    VirtualKey parsed = ParseVirtualKey(bare);

    char msg[256];
    std::snprintf(msg, sizeof(msg), "%s: token '%s' (bare '%s') is not a known key name", name,
                  std::string(token).c_str(), std::string(bare).c_str());
    Report(parsed != VirtualKey::kNone, msg);

    SDL_Scancode scancode = ScancodeFor(bare);
    if (scancode == SDL_SCANCODE_UNKNOWN) continue;

    VirtualKey translated = TranslateSDLScancode(scancode);
    std::snprintf(msg, sizeof(msg),
                  "%s: token '%s' parses 0x%04X but SDL scancode %d translates to 0x%04X", name,
                  std::string(bare).c_str(), uint32_t(parsed), int(scancode),
                  uint32_t(translated));
    Report(parsed == translated, msg);
  }
}

}  // namespace

int main(int argc, char** argv) {
  // Opt-in gate check: RESTREET_INPUT_DIAG must be inert when unset/zero, and
  // active only when set to a non-empty value. Run by the test script with and
  // without the variable.
  if (argc == 3 && std::string_view(argv[1]) == "--diag-gate") {
    const bool expect_enabled = std::string_view(argv[2]) == "enabled";
    const bool enabled = rex::input::diag::Enabled();
    if (enabled == expect_enabled) {
      std::printf("PASS diag gate: Enabled()=%d as expected\n", int(enabled));
      return 0;
    }
    std::printf("FAIL diag gate: Enabled()=%d expected %d\n", int(enabled), int(expect_enabled));
    return 1;
  }

  // Runtime emit check: drive the instrumentation through the real logging path
  // and write to argv[2]. With RESTREET_INPUT_DIAG unset nothing must be
  // written; with it set, exactly one aggregated line must appear.
  if (argc == 3 && std::string_view(argv[1]) == "--emit-check") {
    rex::InitLogging(argv[2], spdlog::level::info);
    rex::input::diag::ObserveSdlKey(/*down=*/true, /*scancode=*/44, /*vk=*/0x20, /*focused=*/true);
    rex::input::diag::ObserveMnkKeyDown(/*driver_enabled=*/true, /*driver_focused=*/true);
    rex::input::diag::ObserveMnkState(/*active=*/true, /*focused=*/true, /*buttons=*/0x1000);
    rex::input::diag::ObserveGuestState(/*user_index=*/0, /*connected=*/true, /*buttons=*/0x1000);
    // The aggregation is rate limited to one line per second, so the first call
    // flushed with only the SDL stage; wait out the window and flush again with
    // the full counter set.
    std::this_thread::sleep_for(std::chrono::milliseconds(1100));
    rex::input::diag::MaybeFlush();
    rex::FlushLogging();
    rex::ShutdownLogging();
    return 0;
  }

  std::printf("== input keybind -> scancode chain ==\n");

  CheckBind("keybind_a", FLAGS_keybind_a_storage_());
  CheckBind("keybind_b", FLAGS_keybind_b_storage_());
  CheckBind("keybind_x", FLAGS_keybind_x_storage_());
  CheckBind("keybind_y", FLAGS_keybind_y_storage_());
  CheckBind("keybind_left_trigger", FLAGS_keybind_left_trigger_storage_());
  CheckBind("keybind_right_trigger", FLAGS_keybind_right_trigger_storage_());
  CheckBind("keybind_left_shoulder", FLAGS_keybind_left_shoulder_storage_());
  CheckBind("keybind_right_shoulder", FLAGS_keybind_right_shoulder_storage_());
  CheckBind("keybind_lstick_up", FLAGS_keybind_lstick_up_storage_());
  CheckBind("keybind_lstick_down", FLAGS_keybind_lstick_down_storage_());
  CheckBind("keybind_lstick_left", FLAGS_keybind_lstick_left_storage_());
  CheckBind("keybind_lstick_right", FLAGS_keybind_lstick_right_storage_());
  CheckBind("keybind_lstick_press", FLAGS_keybind_lstick_press_storage_());
  CheckBind("keybind_rstick_up", FLAGS_keybind_rstick_up_storage_());
  CheckBind("keybind_rstick_down", FLAGS_keybind_rstick_down_storage_());
  CheckBind("keybind_rstick_left", FLAGS_keybind_rstick_left_storage_());
  CheckBind("keybind_rstick_right", FLAGS_keybind_rstick_right_storage_());
  CheckBind("keybind_rstick_press", FLAGS_keybind_rstick_press_storage_());
  CheckBind("keybind_dpad_up", FLAGS_keybind_dpad_up_storage_());
  CheckBind("keybind_dpad_down", FLAGS_keybind_dpad_down_storage_());
  CheckBind("keybind_dpad_left", FLAGS_keybind_dpad_left_storage_());
  CheckBind("keybind_dpad_right", FLAGS_keybind_dpad_right_storage_());
  CheckBind("keybind_back", FLAGS_keybind_back_storage_());
  CheckBind("keybind_start", FLAGS_keybind_start_storage_());
  CheckBind("keybind_guide", FLAGS_keybind_guide_storage_());

  // The A binding must be reachable from a physical Space and Semicolon: this is
  // the FIFA Street "autosave Okay" button the manual session used to continue.
  Report(TranslateSDLScancode(SDL_SCANCODE_SPACE) == ParseVirtualKey("Space"),
         "SDL Space does not translate to the 'Space' bind token");
  Report(TranslateSDLScancode(SDL_SCANCODE_SEMICOLON) == ParseVirtualKey("Semicolon"),
         "SDL Semicolon does not translate to the 'Semicolon' bind token");

  // An unknown physical key must not silently become a real key.
  Report(TranslateSDLScancode(SDL_SCANCODE_UNKNOWN) == VirtualKey::kNone,
         "SDL_SCANCODE_UNKNOWN did not translate to kNone");

  if (g_failures == 0) {
    std::printf("PASS: %d bind tokens checked, 0 failures\n", g_bind_tokens);
    return 0;
  }
  std::printf("FAIL: %d failure(s) across %d bind tokens\n", g_failures, g_bind_tokens);
  return 1;
}
