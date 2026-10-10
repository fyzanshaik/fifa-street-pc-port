// fifastreet - ReXGlue Recompiled Project
//
// Customize your app by overriding virtual hooks from rex::ReXApp.

#pragma once

#include <rex/rex_app.h>
#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/ui/window.h>

#include "guest_frame_capture.h"
#include "control_bridge.h"
#if defined(__APPLE__)
#include "macos_host_defaults.h"
#endif

class FifastreetApp : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<FifastreetApp>(new FifastreetApp(ctx, "fifastreet",
        PPCImageConfig));
  }

  void OnPreSetup(rex::RuntimeConfig& config) override {
#if defined(__APPLE__)
    // Must run before the GPU plugin loads and before any Vulkan instance or
    // device is created: MoltenVK reads MVK_CONFIG_* lazily at first use, and
    // synchronous queue submission is a stable-launch requirement. A Finder
    // double-click has no shell environment, so the default is applied here; an
    // explicit environment value is respected (see macos_host_defaults.h). The
    // persisted stable cvars (vulkan_macos_unpaced_present, macos_idle_*_sleep)
    // come from fifastreet.toml, so a double-click and play-macos.sh agree.
    restreet::host::ApplyMacHostDefaults();
#endif
    if (config.gpu_plugin.empty()) {
      config.gpu_plugin = "xenos";
    }
    // Mac-only, opt-in virtual-gamepad bridge for AI evaluation. Inert unless
    // RESTREET_CONTROL_SOCKET is set, so a normal run keeps the SDK's default
    // input factory. Installed here, before the guest starts, so the driver and
    // its scoped device assignment exist before the first guest poll.
    restreet::control::InstallControlBridge(config);
  }

  void OnConfigurePaths(rex::PathConfig& paths) override {
    if (paths.game_data_root.empty()) {
      const auto executable_folder = rex::filesystem::GetExecutableFolder();
      for (const auto& candidate : {executable_folder, executable_folder / "GameData",
                                   executable_folder.parent_path() / "GameData",
                                   executable_folder.parent_path()}) {
        std::error_code error;
        if (std::filesystem::is_regular_file(candidate / "default.xex", error)) {
          paths.game_data_root = candidate;
          break;
        }
      }
    }
  }

  void OnCreateDialogs(rex::ui::ImGuiDrawer*) override {
    window()->SetTitle("FIFA Street PC");
  }

  void OnPostSetup() override {
    // FIFA Street uses texture fetch descriptors with the invalid-texture tag.
    // Their address and format fields are still valid and must be decoded.
    rex::cvar::SetFlagByName("gpu_allow_invalid_fetch_constants", "true");
    // Mac-only, opt-in rendered-frame evidence (guest_frame_capture.h). Inert
    // unless RESTREET_CAPTURE_DIR is set, so this has no normal-run cost.
    auto* graphics = runtime() ? runtime()->graphics_system() : nullptr;
    guest_frame_capture_.Start(graphics ? graphics->presenter() : nullptr);
  }

  void OnShutdown() override {
    // Join the capture worker before the runtime and presenter are destroyed.
    guest_frame_capture_.Stop();
  }

  // Override virtual hooks for customization:
  // void OnPostInitLogging() override {}
  // void OnPreSetup(rex::RuntimeConfig& config) override {}
  // void OnLoadXexImage(std::string& xex_image) override {}
  // void OnPostLoadXexImage() override {}
  // void OnPostSetup() override {}
  // void OnCreateDialogs(rex::ui::ImGuiDrawer* drawer) override {}
  // std::unique_ptr<rex::ui::ImGuiDialog> CreateAchievementsOverlay() override;
  // std::unique_ptr<rex::ui::AchievementNotificationDialog>
  // CreateAchievementNotificationDialog() override;
  // void OnConfigurePaths(rex::PathConfig& paths) override {}

 private:
  GuestFrameCapture guest_frame_capture_;
};
