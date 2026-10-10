#include "swapchain_present_mode.h"
#include <array>
#include <cstdio>

using rex::ui::vulkan::SelectSwapchainPresentMode;
int main() {
  const std::array all{VK_PRESENT_MODE_FIFO_KHR, VK_PRESENT_MODE_MAILBOX_KHR,
                       VK_PRESENT_MODE_FIFO_RELAXED_KHR, VK_PRESENT_MODE_IMMEDIATE_KHR};
  const std::array fifo{VK_PRESENT_MODE_FIFO_KHR};
  const std::array no_immediate{VK_PRESENT_MODE_FIFO_KHR, VK_PRESENT_MODE_MAILBOX_KHR,
                                VK_PRESENT_MODE_FIFO_RELAXED_KHR};
  unsigned checks = 0, failures = 0;
  auto check = [&](const char* label, VkPresentModeKHR actual, VkPresentModeKHR expected) {
    ++checks;
    if (actual != expected) {
      ++failures;
      std::printf("FAIL %s: got %d, expected %d\n", label, int(actual), int(expected));
    }
  };
  check("vsync default preserves FIFO", SelectSwapchainPresentMode(all, true, true, true, true), VK_PRESENT_MODE_FIFO_KHR);
  check("legacy no-vsync prefers immediate", SelectSwapchainPresentMode(all, false, true, true, true), VK_PRESENT_MODE_IMMEDIATE_KHR);
  check("legacy disabled immediate prefers mailbox", SelectSwapchainPresentMode(all, false, false, true, true), VK_PRESENT_MODE_MAILBOX_KHR);
  check("legacy disabled mailbox prefers relaxed", SelectSwapchainPresentMode(all, false, false, false, true), VK_PRESENT_MODE_FIFO_RELAXED_KHR);
  check("legacy all optional modes disabled", SelectSwapchainPresentMode(all, false, false, false, false), VK_PRESENT_MODE_FIFO_KHR);
  check("no immediate available uses mailbox", SelectSwapchainPresentMode(no_immediate, false, true, true, true), VK_PRESENT_MODE_MAILBOX_KHR);
  check("FIFO-only surface stays valid", SelectSwapchainPresentMode(fifo, false, true, true, true), VK_PRESENT_MODE_FIFO_KHR);
  check("empty enumeration falls back to mandatory FIFO", SelectSwapchainPresentMode({}, false, true, true, true), VK_PRESENT_MODE_FIFO_KHR);
  check("unpaced host with guest vsync uses supported immediate", SelectSwapchainPresentMode(all, true, true, true, true, true), VK_PRESENT_MODE_IMMEDIATE_KHR);
  check("unpaced host honors immediate prohibition", SelectSwapchainPresentMode(all, true, false, true, true, true), VK_PRESENT_MODE_FIFO_KHR);
  check("unpaced host unavailable immediate preserves guest-vsync FIFO", SelectSwapchainPresentMode(no_immediate, true, true, true, true, true), VK_PRESENT_MODE_FIFO_KHR);
  check("unpaced host FIFO-only surface stays valid", SelectSwapchainPresentMode(fifo, true, true, true, true, true), VK_PRESENT_MODE_FIFO_KHR);
  std::printf("Present mode selection: %u/%u checks passed\n", checks-failures, checks);
  return failures ? 1 : 0;
}
