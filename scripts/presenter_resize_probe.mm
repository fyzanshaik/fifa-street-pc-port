// Diagnostic-window probe (no game data, no guest, no input) that drives the real
// production VulkanPresenter through a sequence of window resizes on a real
// MoltenVK device and a real CAMetalLayer surface, feeding a nonblank synthetic
// guest output from a separate "guest output" thread while the UI thread
// processes the resize events - mirroring the production threading model. It
// opens its own small SDL window; it never attaches to the game window.
//
// It exists to reproduce the reported "window goes blank after a resize" bug
// through the production resize/presentation code rather than a text match.
//
// Exit status (validated by scripts/test-macos-presenter-resize.sh):
//   0  all resize checks passed and GPU activity was verified
//   2  usage error
//   3  harness failure (setup, GPU submission/painter failure, or no refresh /
//      paint activity) - the drawable-size check result is not trustworthy
//   4  the drawable-size defect was reproduced (a resize left the CAMetalLayer
//      showing a 1x1 drawable)
//
// Usage:
//   presenter_resize_probe.mm <vulkan-root> <w0> <h0> <w1> <h1> ... (pairs)

#include <rex/cvar.h>
#include <rex/logging/api.h>
#include <rex/ui/presenter.h>
#include <rex/ui/ui_drawer.h>
#include <rex/ui/vulkan/presenter.h>
#include <rex/ui/vulkan/provider.h>
#include <rex/ui/window_sdl.h>
#include <rex/ui/windowed_app_context_sdl.h>

#include <SDL3/SDL.h>

#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

#include <vulkan/vulkan.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <thread>

using rex::ui::Presenter;
using rex::ui::SDLWindowedAppContext;
using rex::ui::WindowSDL;
using rex::ui::vulkan::VulkanDevice;
using rex::ui::vulkan::VulkanPresenter;
using rex::ui::vulkan::VulkanProvider;
using VulkanGuestOutputRefreshContext =
    rex::ui::vulkan::VulkanPresenter::VulkanGuestOutputRefreshContext;

namespace {

// Drawable sizes the window must reach within the resize-processing allowance.
constexpr auto kResizeProcessTimeout = std::chrono::milliseconds(1500);
// A guest-output refresh must not be able to hang the probe on a GPU stall.
constexpr uint64_t kFenceTimeoutNs = 5'000'000'000ULL;
// Minimum successful refreshes required before the resize checks are trusted.
constexpr uint64_t kMinRefreshActivity = 3;

constexpr int kExitPass = 0;
constexpr int kExitUsage = 2;
constexpr int kExitHarness = 3;
constexpr int kExitDrawableDefect = 4;

std::atomic<uint64_t> g_paint_events{0};

// Registers a UI drawer so the presenter takes the kUIThreadOnRequest paint
// path (the real game always has the idle exit/toast overlay registered).
struct NoopDrawer final : rex::ui::UIDrawer {
  void Draw(rex::ui::UIDrawContext&) override {}
};

void Pump(SDLWindowedAppContext& context, WindowSDL& window, int max_events = 256) {
  SDL_Event event;
  for (int i = 0; i < max_events && SDL_PollEvent(&event); ++i) {
    if (event.type == context.paint_event_type()) {
      g_paint_events.fetch_add(1, std::memory_order_relaxed);
      window.HandlePaintEvent();
    } else if (event.type >= SDL_EVENT_WINDOW_FIRST && event.type <= SDL_EVENT_WINDOW_LAST) {
      window.HandleWindowEvent(event);
    }
  }
  [NSApp updateWindows];
}

// Writes a solid nonblank color into the guest output image provided by the
// context, using a render pass because the guest output image does not have the
// transfer-destination usage.
struct GuestOutputPainter {
  const VulkanDevice* device = nullptr;
  VkRenderPass render_pass = VK_NULL_HANDLE;
  VkCommandPool command_pool = VK_NULL_HANDLE;
  VkCommandBuffer command_buffer = VK_NULL_HANDLE;
  VkFence fence = VK_NULL_HANDLE;
  // Any Vulkan recording/reset/submit/wait failure is a real GPU-path defect
  // for this synthetic clear; count them so the probe never pretends Paint
  // succeeded.
  std::atomic<uint64_t> hard_failures{0};

  bool Initialize(const VulkanDevice* device_in) {
    device = device_in;
    const VkDevice vk_device = device->device();
    const VulkanDevice::Functions& dfn = device->functions();

    VkAttachmentDescription attachment{};
    attachment.format = VulkanPresenter::kGuestOutputFormat;
    attachment.samples = VK_SAMPLE_COUNT_1_BIT;
    attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    attachment.finalLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    VkAttachmentReference color_reference{};
    color_reference.attachment = 0;
    color_reference.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    VkSubpassDescription subpass{};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &color_reference;
    VkRenderPassCreateInfo render_pass_info{};
    render_pass_info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    render_pass_info.attachmentCount = 1;
    render_pass_info.pAttachments = &attachment;
    render_pass_info.subpassCount = 1;
    render_pass_info.pSubpasses = &subpass;
    if (dfn.vkCreateRenderPass(vk_device, &render_pass_info, nullptr, &render_pass) != VK_SUCCESS) {
      return false;
    }
    VkCommandPoolCreateInfo pool_info{};
    pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = device->queue_family_graphics_compute();
    if (dfn.vkCreateCommandPool(vk_device, &pool_info, nullptr, &command_pool) != VK_SUCCESS) {
      return false;
    }
    VkCommandBufferAllocateInfo command_info{};
    command_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    command_info.commandPool = command_pool;
    command_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    command_info.commandBufferCount = 1;
    if (dfn.vkAllocateCommandBuffers(vk_device, &command_info, &command_buffer) != VK_SUCCESS) {
      return false;
    }
    VkFenceCreateInfo fence_info{};
    fence_info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if (dfn.vkCreateFence(vk_device, &fence_info, nullptr, &fence) != VK_SUCCESS) {
      return false;
    }
    return true;
  }

  bool Paint(const VkImageView image_view, uint32_t width, uint32_t height) {
    const VkDevice vk_device = device->device();
    const VulkanDevice::Functions& dfn = device->functions();
    VkFramebufferCreateInfo framebuffer_info{};
    framebuffer_info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    framebuffer_info.renderPass = render_pass;
    framebuffer_info.attachmentCount = 1;
    framebuffer_info.pAttachments = &image_view;
    framebuffer_info.width = width;
    framebuffer_info.height = height;
    framebuffer_info.layers = 1;
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
    if (dfn.vkCreateFramebuffer(vk_device, &framebuffer_info, nullptr, &framebuffer) != VK_SUCCESS) {
      hard_failures.fetch_add(1, std::memory_order_relaxed);
      return false;
    }
    bool recorded = false;
    do {
      if (dfn.vkResetCommandPool(vk_device, command_pool, 0) != VK_SUCCESS) {
        break;
      }
      VkCommandBufferBeginInfo begin_info{};
      begin_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
      begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
      if (dfn.vkBeginCommandBuffer(command_buffer, &begin_info) != VK_SUCCESS) {
        break;
      }
      VkRenderPassBeginInfo pass_info{};
      pass_info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
      pass_info.renderPass = render_pass;
      pass_info.framebuffer = framebuffer;
      pass_info.renderArea.extent = {width, height};
      VkClearValue clear{};
      clear.color.float32[0] = 0.1f;
      clear.color.float32[1] = 0.9f;
      clear.color.float32[2] = 0.2f;
      clear.color.float32[3] = 1.0f;
      pass_info.clearValueCount = 1;
      pass_info.pClearValues = &clear;
      dfn.vkCmdBeginRenderPass(command_buffer, &pass_info, VK_SUBPASS_CONTENTS_INLINE);
      dfn.vkCmdEndRenderPass(command_buffer);
      if (dfn.vkEndCommandBuffer(command_buffer) != VK_SUCCESS) {
        break;
      }
      if (dfn.vkResetFences(vk_device, 1, &fence) != VK_SUCCESS) {
        break;
      }
      recorded = true;
    } while (false);
    if (!recorded) {
      dfn.vkDestroyFramebuffer(vk_device, framebuffer, nullptr);
      hard_failures.fetch_add(1, std::memory_order_relaxed);
      return false;
    }
    // Host access to a VkQueue must be externally synchronized. Acquire the
    // queue's lock here - at the submission site - and retain the acquisition
    // through vkQueueSubmit and the fence wait, so this does not submit on a raw
    // queue handle unlocked concurrently with the presenter.
    const VulkanDevice::Queue::Acquisition queue_acquisition =
        device->AcquireQueue(device->queue_family_graphics_compute(), 0);
    VkSubmitInfo submit{};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &command_buffer;
    bool ok = dfn.vkQueueSubmit(queue_acquisition.queue(), 1, &submit, fence) == VK_SUCCESS;
    if (ok) {
      ok = dfn.vkWaitForFences(vk_device, 1, &fence, VK_TRUE, kFenceTimeoutNs) == VK_SUCCESS;
    }
    dfn.vkDestroyFramebuffer(vk_device, framebuffer, nullptr);
    if (!ok) {
      hard_failures.fetch_add(1, std::memory_order_relaxed);
    }
    return ok;
  }

  // Destroys the device-scoped objects while the VulkanDevice is still alive.
  void Shutdown() {
    if (!device) {
      return;
    }
    const VkDevice vk_device = device->device();
    const VulkanDevice::Functions& dfn = device->functions();
    if (fence != VK_NULL_HANDLE) {
      dfn.vkDestroyFence(vk_device, fence, nullptr);
      fence = VK_NULL_HANDLE;
    }
    if (command_pool != VK_NULL_HANDLE) {
      dfn.vkDestroyCommandPool(vk_device, command_pool, nullptr);
      command_pool = VK_NULL_HANDLE;
      command_buffer = VK_NULL_HANDLE;
    }
    if (render_pass != VK_NULL_HANDLE) {
      dfn.vkDestroyRenderPass(vk_device, render_pass, nullptr);
      render_pass = VK_NULL_HANDLE;
    }
    device = nullptr;
  }
};

int Fail(const char* what) {
  std::fprintf(stderr, "PROBE FAIL: %s\n", what);
  return kExitHarness;
}

// Finds the CAMetalLayer backing SDL's Metal view (a subview of the window's
// content view).
CAMetalLayer* FindMetalLayer(SDL_Window* sdl_window) {
  SDL_PropertiesID props = SDL_GetWindowProperties(sdl_window);
  auto* ns_window = static_cast<NSWindow*>(
      SDL_GetPointerProperty(props, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr));
  if (!ns_window) {
    return nil;
  }
  NSView* view = [ns_window contentView];
  for (NSView* subview in [view subviews]) {
    if ([[subview layer] isKindOfClass:[CAMetalLayer class]]) {
      return (CAMetalLayer*)[subview layer];
    }
    for (NSView* subsubview in [subview subviews]) {
      if ([[subsubview layer] isKindOfClass:[CAMetalLayer class]]) {
        return (CAMetalLayer*)[subsubview layer];
      }
    }
  }
  return nil;
}

struct ResizeObservation {
  uint32_t pixel_width = 0;
  uint32_t pixel_height = 0;
  bool layer_matched = false;
};

// Pumps the UI loop until the window's surface pixel size has settled and the
// presenter has processed the resize (its CAMetalLayer drawable size reached
// the surface pixel size), or until the deadline. The expected size comes from
// SDL_GetWindowSizeInPixels (physical surface pixels), not the requested
// logical width, so a Retina surface is compared in the same unit as the layer.
ResizeObservation PumpUntilResizeProcessed(SDLWindowedAppContext& context, WindowSDL& window,
                                           SDL_Window* sdl_window) {
  const auto deadline = std::chrono::steady_clock::now() + kResizeProcessTimeout;
  ResizeObservation observation;
  uint32_t last_width = 0;
  uint32_t last_height = 0;
  int stable_samples = 0;
  while (std::chrono::steady_clock::now() < deadline) {
    SDL_PumpEvents();
    Pump(context, window);
    int pixel_width = 0;
    int pixel_height = 0;
    SDL_GetWindowSizeInPixels(sdl_window, &pixel_width, &pixel_height);
    if (pixel_width > 0 && pixel_height > 0) {
      if (uint32_t(pixel_width) == last_width && uint32_t(pixel_height) == last_height) {
        ++stable_samples;
      } else {
        stable_samples = 0;
      }
      last_width = uint32_t(pixel_width);
      last_height = uint32_t(pixel_height);
    }
    if (stable_samples >= 2) {
      observation.pixel_width = last_width;
      observation.pixel_height = last_height;
      if (CAMetalLayer* metal_layer = FindMetalLayer(sdl_window)) {
        if (uint32_t(metal_layer.drawableSize.width) == last_width &&
            uint32_t(metal_layer.drawableSize.height) == last_height) {
          observation.layer_matched = true;
          break;
        }
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return observation;
}

// The defect under test: after the presenter reconnects for a resize,
// MoltenVK's forceUnpresentedImageCompletion workaround must not leave the
// CAMetalLayer showing a 1x1 drawable stretched over the window. The drawable
// size must be the surface pixel size the swapchain was created for.
bool CheckLayerDrawableSize(SDL_Window* sdl_window, uint32_t expected_width,
                            uint32_t expected_height, int& failures) {
  CAMetalLayer* metal_layer = FindMetalLayer(sdl_window);
  uint32_t drawable_width = 0;
  uint32_t drawable_height = 0;
  if (metal_layer) {
    drawable_width = uint32_t(metal_layer.drawableSize.width);
    drawable_height = uint32_t(metal_layer.drawableSize.height);
  }
  const bool ok =
      metal_layer && drawable_width == expected_width && drawable_height == expected_height;
  std::printf("PROBE after-resize: expected_drawable=%ux%u actual_drawable=%ux%u %s\n",
              expected_width, expected_height, drawable_width, drawable_height,
              ok ? "OK" : "MISMATCH");
  if (!ok) {
    ++failures;
  }
  return ok;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 6 || (argc % 2) != 0) {
    std::fprintf(stderr, "usage: %s <vulkan-root> <w0> <h0> <w1> <h1> [<w2> <h2> ...]\n",
                 argv[0]);
    return kExitUsage;
  }
  const char* vulkan_root = argv[1];
  (void)vulkan_root;
  const uint32_t width0 = uint32_t(std::atoi(argv[2]));
  const uint32_t height0 = uint32_t(std::atoi(argv[3]));

  rex::InitLoggingEarly();
  rex::cvar::SetFlagByName("vulkan_macos_unpaced_present", "true");
  rex::cvar::SetFlagByName("vulkan_allow_present_mode_immediate", "true");
  rex::cvar::SetFlagByName("vsync", "true");

  SDLWindowedAppContext context;
  if (!context.Initialize()) {
    return Fail("SDL app context initialize");
  }

  auto window = std::make_unique<WindowSDL>(context, "presenter-resize-probe", width0, height0);
  if (!window->Open()) {
    return Fail("window open");
  }
  // Keep the default activation policy so the SDL window is a normal window, but
  // do not activate or focus it: the resize/present reproduction is driven by
  // SDL_SetWindowSize and does not depend on the window being frontmost.
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  SDL_Window* sdl_window = nullptr;
  {
    int window_count = 0;
    SDL_Window** windows = SDL_GetWindows(&window_count);
    if (windows && window_count > 0) {
      sdl_window = windows[0];
    }
  }
  if (!sdl_window) {
    return Fail("SDL window handle");
  }

  auto provider = VulkanProvider::Create(false, true);
  if (!provider) {
    return Fail("VulkanProvider::Create");
  }
  auto presenter = provider->CreatePresenter([](bool, bool) {});
  if (!presenter) {
    return Fail("CreatePresenter");
  }
  auto* vulkan_presenter = static_cast<VulkanPresenter*>(presenter.get());

  window->SetPresenter(presenter.get());
  Pump(context, *window);

  NoopDrawer drawer;
  // The shipping runtime always has the sleeping idle exit/toast overlay
  // registered as a UI drawer, which is what selects the kUIThreadOnRequest
  // paint path; mirror that so the reproducer exercises the real paint path.
  presenter->AddUIDrawerFromUIThread(&drawer, 0);
  Pump(context, *window);

  GuestOutputPainter painter;
  if (!painter.Initialize(vulkan_presenter->vulkan_device())) {
    return Fail("guest output painter initialize");
  }

  std::atomic<bool> stop{false};
  std::atomic<uint64_t> refreshes_ok{0};
  std::atomic<uint64_t> refreshes_refused{0};
  std::thread guest_output_thread([&]() {
    while (!stop.load(std::memory_order_relaxed)) {
      const bool refreshed = presenter->RefreshGuestOutput(
          width0, height0, 16, 9,
          [&](Presenter::GuestOutputRefreshContext& refresh_context) {
            auto& vulkan_context = static_cast<VulkanGuestOutputRefreshContext&>(refresh_context);
            vulkan_context.SetIs8bpc(true);
            return painter.Paint(vulkan_context.image_view(), width0, height0);
          });
      if (refreshed) {
        refreshes_ok.fetch_add(1, std::memory_order_relaxed);
      } else {
        refreshes_refused.fetch_add(1, std::memory_order_relaxed);
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  });

  // Warm-up: process paint events so the presenter establishes the surface
  // connection and presents before the resize checks, and so refresh/present
  // activity can be asserted.
  {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(800);
    while (std::chrono::steady_clock::now() < deadline) {
      SDL_PumpEvents();
      Pump(context, *window);
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  }

  int failures = 0;
  int exit_code = kExitPass;
  const auto refresh_stats = [&]() {
    return std::pair<uint64_t, uint64_t>(refreshes_ok.load(std::memory_order_relaxed),
                                         refreshes_refused.load(std::memory_order_relaxed));
  };
  const uint64_t paint_events = g_paint_events.load(std::memory_order_relaxed);
  const uint64_t painter_failures = painter.hard_failures.load(std::memory_order_relaxed);
  if (refreshes_ok.load(std::memory_order_relaxed) < kMinRefreshActivity) {
    const auto [ok, refused] = refresh_stats();
    std::fprintf(stderr,
                 "PROBE FAIL: no successful guest output refresh before resizes "
                 "(ok=%llu refused=%llu)\n",
                 (unsigned long long)ok, (unsigned long long)refused);
    exit_code = kExitHarness;
  } else if (paint_events == 0) {
    std::fprintf(stderr, "PROBE FAIL: no presenter paint events observed before resizes\n");
    exit_code = kExitHarness;
  } else if (refreshes_refused.load(std::memory_order_relaxed) != 0 || painter_failures != 0) {
    const auto [ok, refused] = refresh_stats();
    std::fprintf(stderr,
                 "PROBE FAIL: guest output refresh/painter failure before resizes "
                 "(ok=%llu refused=%llu hard=%llu)\n",
                 (unsigned long long)ok, (unsigned long long)refused,
                 (unsigned long long)painter_failures);
    exit_code = kExitHarness;
  }

  if (exit_code == kExitPass) {
    for (int arg = 4; arg + 1 < argc; arg += 2) {
      const uint32_t width = uint32_t(std::atoi(argv[arg]));
      const uint32_t height = uint32_t(std::atoi(argv[arg + 1]));
      std::printf("PROBE resize to %ux%u\n", width, height);
      SDL_SetWindowSize(sdl_window, int(width), int(height));
      SDL_SyncWindow(sdl_window);
      const ResizeObservation observation =
          PumpUntilResizeProcessed(context, *window, sdl_window);
      if (std::getenv("PROBE_FORCE_CLOBBER")) {
        // Negative control: emulate the unfixed presenter by putting the layer
        // back into MoltenVK's 1x1 state after the presenter has processed the
        // resize, then sample it immediately without waiting for recovery.
        if (CAMetalLayer* metal_layer = FindMetalLayer(sdl_window)) {
          metal_layer.drawableSize = CGSizeMake(1, 1);
        }
      }
      if (observation.pixel_width == 0 || observation.pixel_height == 0) {
        std::fprintf(stderr, "PROBE FAIL: window surface pixel size never settled\n");
        exit_code = kExitHarness;
        break;
      }
      CheckLayerDrawableSize(sdl_window, observation.pixel_width, observation.pixel_height,
                             failures);
    }
    if (exit_code == kExitPass &&
        (refreshes_refused.load(std::memory_order_relaxed) != 0 ||
         painter.hard_failures.load(std::memory_order_relaxed) != 0)) {
      const auto [ok, refused] = refresh_stats();
      std::fprintf(stderr,
                   "PROBE FAIL: guest output refresh/painter failure during resizes "
                   "(ok=%llu refused=%llu hard=%llu)\n",
                   (unsigned long long)ok, (unsigned long long)refused,
                   (unsigned long long)painter.hard_failures.load(std::memory_order_relaxed));
      exit_code = kExitHarness;
    }
  }

  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  stop.store(true, std::memory_order_relaxed);
  guest_output_thread.join();

  {
    const auto [ok, refused] = refresh_stats();
    std::printf("PROBE activity: refreshes_ok=%llu refreshes_refused=%llu paint_events=%llu "
                "painter_hard_failures=%llu\n",
                (unsigned long long)ok, (unsigned long long)refused,
                (unsigned long long)g_paint_events.load(std::memory_order_relaxed),
                (unsigned long long)painter.hard_failures.load(std::memory_order_relaxed));
  }

  window->SetPresenter(nullptr);
  presenter->RemoveUIDrawerFromUIThread(&drawer);
  painter.Shutdown();
  presenter.reset();
  provider.reset();
  window.reset();

  if (exit_code == kExitPass && failures != 0) {
    std::printf("PROBE FAIL: drawable-size defect on %d resize(s)\n", failures);
    rex::ShutdownLogging();
    return kExitDrawableDefect;
  }
  if (exit_code != kExitPass) {
    rex::ShutdownLogging();
    return exit_code;
  }
  std::printf("PROBE PASS: CAMetalLayer drawable size matches the surface after every resize\n");
  rex::ShutdownLogging();
  return kExitPass;
}
