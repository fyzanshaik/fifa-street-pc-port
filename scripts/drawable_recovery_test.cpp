/**
 ******************************************************************************
 * ReStreet : macOS drawable-exhaustion acquire recovery regression test
 ******************************************************************************
 *
 * Links the real helper used by VulkanPresenter::PaintAndPresentImpl
 * (ReXGlue/src/ui/vulkan/swapchain_acquire_recovery.h) so the mapping is
 * exercised as compiled code, not as a copy or a text match.
 *
 * The case that matters: MoltenVK reports VK_ERROR_OUT_OF_POOL_MEMORY from
 * MVKPresentableSwapchainImage::getCAMetalDrawable() to request swapchain
 * re-establishment, and that must classify as kReconnect only on the macOS
 * MoltenVK runtime; every other acquire result must keep its previous
 * classification on both platforms.
 */

#include "swapchain_acquire_recovery.h"

#include <cstdio>

using rex::ui::vulkan::ClassifySwapchainAcquireResult;
using rex::ui::vulkan::SwapchainAcquireOutcome;

namespace {

int failures = 0;

const char* Name(SwapchainAcquireOutcome outcome) {
  switch (outcome) {
    case SwapchainAcquireOutcome::kProceed:
      return "kProceed";
    case SwapchainAcquireOutcome::kRetry:
      return "kRetry";
    case SwapchainAcquireOutcome::kReconnect:
      return "kReconnect";
    case SwapchainAcquireOutcome::kDeviceLost:
      return "kDeviceLost";
    case SwapchainAcquireOutcome::kFailed:
      return "kFailed";
  }
  return "?";
}

void Expect(const char* what, VkResult result, bool moltenvk_present,
            SwapchainAcquireOutcome expected) {
  const SwapchainAcquireOutcome actual = ClassifySwapchainAcquireResult(result, moltenvk_present);
  if (actual == expected) {
    std::printf("ok   %-28s -> %s\n", what, Name(actual));
    return;
  }
  std::printf("FAIL %-28s (result=%d moltenvk=%d): expected %s, got %s\n", what, int(result),
              moltenvk_present ? 1 : 0, Name(expected), Name(actual));
  ++failures;
}

}  // namespace

int main() {
  // An image was acquired; drawing continues.
  Expect("VK_SUCCESS", VK_SUCCESS, false, SwapchainAcquireOutcome::kProceed);
  Expect("VK_SUCCESS [mac]", VK_SUCCESS, true, SwapchainAcquireOutcome::kProceed);
  Expect("VK_SUBOPTIMAL_KHR", VK_SUBOPTIMAL_KHR, false, SwapchainAcquireOutcome::kProceed);
  Expect("VK_SUBOPTIMAL_KHR [mac]", VK_SUBOPTIMAL_KHR, true, SwapchainAcquireOutcome::kProceed);

  // No image yet; drop the frame but keep the swapchain.
  Expect("VK_TIMEOUT", VK_TIMEOUT, false, SwapchainAcquireOutcome::kRetry);
  Expect("VK_TIMEOUT [mac]", VK_TIMEOUT, true, SwapchainAcquireOutcome::kRetry);
  Expect("VK_NOT_READY", VK_NOT_READY, false, SwapchainAcquireOutcome::kRetry);
  Expect("VK_NOT_READY [mac]", VK_NOT_READY, true, SwapchainAcquireOutcome::kRetry);

  // Ordinary outdated results recreate the swapchain on every driver.
  Expect("VK_ERROR_OUT_OF_DATE_KHR", VK_ERROR_OUT_OF_DATE_KHR, false,
         SwapchainAcquireOutcome::kReconnect);
  Expect("VK_ERROR_OUT_OF_DATE_KHR [mac]", VK_ERROR_OUT_OF_DATE_KHR, true,
         SwapchainAcquireOutcome::kReconnect);
  Expect("VK_ERROR_SURFACE_LOST_KHR", VK_ERROR_SURFACE_LOST_KHR, false,
         SwapchainAcquireOutcome::kReconnect);
  Expect("VK_ERROR_SURFACE_LOST_KHR [mac]", VK_ERROR_SURFACE_LOST_KHR, true,
         SwapchainAcquireOutcome::kReconnect);
  Expect("FULL_SCREEN_EXCLUSIVE_MODE_LOST", VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT, false,
         SwapchainAcquireOutcome::kReconnect);
  Expect("FULL_SCREEN_EXCLUSIVE_MODE_LOST [mac]", VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT,
         true, SwapchainAcquireOutcome::kReconnect);

  // Genuine device loss is still forwarded as such, not turned into a reset.
  Expect("VK_ERROR_DEVICE_LOST", VK_ERROR_DEVICE_LOST, false,
         SwapchainAcquireOutcome::kDeviceLost);
  Expect("VK_ERROR_DEVICE_LOST [mac]", VK_ERROR_DEVICE_LOST, true,
         SwapchainAcquireOutcome::kDeviceLost);

  // The defect under test: MoltenVK's drawable-exhaustion result must request
  // swapchain recreation on macOS, and must stay an unclassified failure (the
  // old default: drop and log) on every other driver.
  Expect("VK_ERROR_OUT_OF_POOL_MEMORY [mac]", VK_ERROR_OUT_OF_POOL_MEMORY, true,
         SwapchainAcquireOutcome::kReconnect);
  Expect("VK_ERROR_OUT_OF_POOL_MEMORY", VK_ERROR_OUT_OF_POOL_MEMORY, false,
         SwapchainAcquireOutcome::kFailed);

  // Results the presenter never special-cased must stay unchanged.
  Expect("VK_ERROR_OUT_OF_HOST_MEMORY", VK_ERROR_OUT_OF_HOST_MEMORY, false,
         SwapchainAcquireOutcome::kFailed);
  Expect("VK_ERROR_OUT_OF_HOST_MEMORY [mac]", VK_ERROR_OUT_OF_HOST_MEMORY, true,
         SwapchainAcquireOutcome::kFailed);
  Expect("VK_ERROR_OUT_OF_DEVICE_MEMORY", VK_ERROR_OUT_OF_DEVICE_MEMORY, false,
         SwapchainAcquireOutcome::kFailed);
  Expect("VK_ERROR_OUT_OF_DEVICE_MEMORY [mac]", VK_ERROR_OUT_OF_DEVICE_MEMORY, true,
         SwapchainAcquireOutcome::kFailed);

  if (failures != 0) {
    std::printf("\n%d check(s) FAILED\n", failures);
    return 1;
  }
  std::printf("\nAll drawable-recovery checks passed\n");
  return 0;
}
