/**
 ******************************************************************************
 * ReStreet : macOS acquire-synchronization recovery after a reconnect test
 ******************************************************************************
 *
 * Links the real helper used by VulkanPresenter::PaintAndPresentImpl and
 * PaintContext::RecoverAcquireSyncAfterRetirement
 * (ReXGlue/src/ui/vulkan/swapchain_acquire_sync_recovery.h), driving it through
 * an instrumented fake dispatch that models the presenter lifecycle:
 *
 *   reconnect-class acquire (the acquire semaphore may have been signaled by
 *   MoltenVK) -> swapchain retirement with the old references finished -> the
 *   acquire semaphore/fence are replaced -> the next acquire uses the fresh,
 *   unsignaled synchronization.
 *
 * The helper never waits, so a signal MoltenVK has not emitted yet cannot block
 * it; the test also covers a delayed signal to the dropped acquire's semaphore,
 * creation failures, and the shutdown path. No GPU, thread, SDK or guest code.
 */

#include "swapchain_acquire_sync_recovery.h"

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using rex::ui::vulkan::AcquireSyncHandles;
using rex::ui::vulkan::AcquireSyncOps;
using rex::ui::vulkan::ReplacePendingAcquireSync;

namespace {

int failures = 0;

void Check(const char* what, bool condition) {
  if (condition) {
    std::printf("ok   %s\n", what);
    return;
  }
  std::printf("FAIL %s\n", what);
  ++failures;
}

VkSemaphore SemaphoreHandle(uint32_t id) {
  return reinterpret_cast<VkSemaphore>(static_cast<uintptr_t>(id));
}

VkFence FenceHandle(uint32_t id) {
  return reinterpret_cast<VkFence>(static_cast<uintptr_t>(id));
}

// Instrumented fake dispatch: records the exact order of the create/destroy
// calls and can inject creation failures. It deliberately offers no wait or
// reset - the production helper must not require one.
struct FakeDispatch {
  uint32_t next_id = 1000;
  bool fail_semaphore = false;
  bool fail_fence = false;
  std::vector<std::string> events;
  VkSemaphore last_destroyed_semaphore = VK_NULL_HANDLE;
  VkFence last_destroyed_fence = VK_NULL_HANDLE;

  VkResult CreateSemaphore(VkSemaphore* out) {
    if (fail_semaphore) {
      events.push_back("create_semaphore(fail)");
      return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    *out = SemaphoreHandle(next_id++);
    events.push_back("create_semaphore");
    return VK_SUCCESS;
  }
  VkResult CreateFence(VkFence* out) {
    if (fail_fence) {
      events.push_back("create_fence(fail)");
      return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    *out = FenceHandle(next_id++);
    events.push_back("create_fence");
    return VK_SUCCESS;
  }
  void DestroySemaphore(VkSemaphore semaphore) {
    events.push_back("destroy_semaphore");
    last_destroyed_semaphore = semaphore;
  }
  void DestroyFence(VkFence fence) {
    events.push_back("destroy_fence");
    last_destroyed_fence = fence;
  }

  AcquireSyncOps ops() {
    return AcquireSyncOps{
        [](void* context, VkSemaphore* out) {
          return static_cast<FakeDispatch*>(context)->CreateSemaphore(out);
        },
        [](void* context, VkFence* out) {
          return static_cast<FakeDispatch*>(context)->CreateFence(out);
        },
        [](void* context, VkSemaphore semaphore) {
          static_cast<FakeDispatch*>(context)->DestroySemaphore(semaphore);
        },
        [](void* context, VkFence fence) {
          static_cast<FakeDispatch*>(context)->DestroyFence(fence);
        },
        this,
    };
  }
};

bool EventsAre(const std::vector<std::string>& events, const std::vector<std::string>& expected) {
  return events == expected;
}

// Models the presenter's submission slots and swapchain-reconnect ordering.
// Replacement is only performed at the retirement boundary, after RefsFinished,
// mirroring PaintContext::PrepareForSwapchainRetirement.
struct PresenterModel {
  static constexpr uint32_t kSlotCount = 3;

  FakeDispatch dispatch;
  AcquireSyncHandles handles[kSlotCount];
  uint32_t pending = 0;
  uint32_t failed = 0;
  uint32_t swapchain_generation = 0;
  bool refs_finished = false;
  VkSemaphore last_acquired_handle[kSlotCount] = {VK_NULL_HANDLE, VK_NULL_HANDLE,
                                                  VK_NULL_HANDLE};

  PresenterModel() {
    for (uint32_t slot = 0; slot < kSlotCount; ++slot) {
      handles[slot].semaphore = SemaphoreHandle(1 + slot);
      handles[slot].fence = FenceHandle(100 + slot);
    }
  }

  // The receive side of vkAcquireNextImageKHR returning a reconnect-class
  // result while the swapchain is still live: only noted, nothing is touched
  // until the swapchain is retired.
  void AcquireReconnect(uint32_t slot) { pending |= uint32_t(1) << slot; }

  // All submissions completed and the queues are idle.
  void RefsFinished() { refs_finished = true; }

  // PaintContext::PrepareForSwapchainRetirement: the only place replacement is
  // allowed, because the old handles must have no in-flight references.
  uint32_t RetireAndReplace() {
    if (!refs_finished) {
      std::printf("FAIL replacement attempted before references finished\n");
      ++failures;
    }
    const uint32_t newly_failed =
        ReplacePendingAcquireSync(dispatch.ops(), pending, handles, kSlotCount);
    failed |= newly_failed;
    pending = newly_failed;
    ++swapchain_generation;
    return newly_failed;
  }

  // The next vkAcquireNextImageKHR on the new swapchain. A slot whose
  // replacement failed is never reused (the presenter reports GPU loss then).
  VkSemaphore NextAcquire(uint32_t slot) {
    if (failed & (uint32_t(1) << slot)) {
      return VK_NULL_HANDLE;
    }
    last_acquired_handle[slot] = handles[slot].semaphore;
    return handles[slot].semaphore;
  }
};

// The defect: MoltenVK signals the acquire semaphore before returning a
// reconnect-class result, so after the reconnect the presenter must not pass
// that same, possibly-signaled semaphore to the next acquire.
void TestPendingSlotIsReplaced() {
  PresenterModel model;
  const VkSemaphore dropped_semaphore = model.handles[0].semaphore;
  const VkFence dropped_fence = model.handles[0].fence;

  model.AcquireReconnect(0);
  Check("no synchronization is touched before retirement", model.dispatch.events.empty());
  Check("the dropped acquire semaphore was the one already in the slot",
        model.handles[0].semaphore == dropped_semaphore);

  model.RefsFinished();
  model.RetireAndReplace();

  Check("pending slot acquire semaphore replaced", model.handles[0].semaphore != dropped_semaphore);
  Check("pending slot acquire fence replaced", model.handles[0].fence != dropped_fence);
  Check("dropped acquire semaphore destroyed only at retirement",
        model.dispatch.last_destroyed_semaphore == dropped_semaphore);
  Check("dropped acquire fence destroyed only at retirement",
        model.dispatch.last_destroyed_fence == dropped_fence);
  Check("new pair created before the old pair is destroyed",
        EventsAre(model.dispatch.events, {"create_semaphore", "create_fence", "destroy_semaphore",
                                          "destroy_fence"}));
  Check("next acquire on the new swapchain uses the replaced semaphore",
        model.NextAcquire(0) == model.handles[0].semaphore);
  Check("next acquire semaphore differs from the dropped one",
        model.last_acquired_handle[0] != dropped_semaphore);
}

// The replacement must not wait for, reset, or otherwise touch a signal that is
// still pending; a delayed signal to the old semaphore is simply irrelevant to
// the new one.
void TestDelayedSignalingIsIrrelevant() {
  PresenterModel model;
  const VkSemaphore dropped_semaphore = model.handles[1].semaphore;

  model.AcquireReconnect(1);
  model.RefsFinished();
  model.RetireAndReplace();

  const VkSemaphore replacement = model.NextAcquire(1);
  Check("delayed-signaling slot replaced before the next acquire",
        replacement != dropped_semaphore);
  // The dropped acquire's queued signal (delivered when the old swapchain's
  // image is retired) targets the old handle, which is no longer the slot's.
  const bool delayed_signal_can_reach_new = (dropped_semaphore == replacement);
  Check("a delayed signal to the dropped acquire cannot reach the next acquire",
        !delayed_signal_can_reach_new);
}

// Slots that were not noted must be left exactly as they were.
void TestUntouchedSlotsUnchanged() {
  PresenterModel model;
  const VkSemaphore slot0 = model.handles[0].semaphore;
  const VkFence slot2 = model.handles[2].fence;

  model.AcquireReconnect(1);
  model.RefsFinished();
  model.RetireAndReplace();

  Check("unnoted slot semaphore unchanged", model.handles[0].semaphore == slot0);
  Check("unnoted slot fence unchanged", model.handles[2].fence == slot2);
  Check("only the noted slot's synchronization was created",
        EventsAre(model.dispatch.events, {"create_semaphore", "create_fence", "destroy_semaphore",
                                          "destroy_fence"}));
}

// If the replacement semaphore cannot be created, the existing handles must be
// kept (never left dangling) and the slot must be reported so it is not reused.
void TestSemaphoreCreationFailure() {
  PresenterModel model;
  const VkSemaphore existing_semaphore = model.handles[2].semaphore;
  const VkFence existing_fence = model.handles[2].fence;

  model.AcquireReconnect(2);
  model.RefsFinished();
  model.dispatch.fail_semaphore = true;
  const uint32_t newly_failed = model.RetireAndReplace();

  Check("semaphore creation failure reports the slot", newly_failed == (uint32_t(1) << 2));
  Check("semaphore creation failure keeps the existing handles",
        model.handles[2].semaphore == existing_semaphore &&
            model.handles[2].fence == existing_fence);
  Check("semaphore creation failure does not destroy the existing semaphore",
        model.dispatch.last_destroyed_semaphore == VK_NULL_HANDLE);
  Check("presenter refuses to reuse a slot whose replacement failed",
        model.NextAcquire(2) == VK_NULL_HANDLE);
}

// A fence creation failure after the semaphore was created must discard the
// partial semaphore and keep the existing pair.
void TestFenceCreationFailure() {
  PresenterModel model;
  const VkSemaphore existing_semaphore = model.handles[0].semaphore;

  model.AcquireReconnect(0);
  model.RefsFinished();
  model.dispatch.fail_fence = true;
  const uint32_t newly_failed = model.RetireAndReplace();

  Check("fence creation failure reports the slot", newly_failed == (uint32_t(1) << 0));
  Check("fence creation failure keeps the existing handles",
        model.handles[0].semaphore == existing_semaphore);
  Check("partial new semaphore is discarded on fence failure",
        EventsAre(model.dispatch.events, {"create_semaphore", "create_fence(fail)",
                                          "destroy_semaphore"}));
}

// Shutdown: with nothing pending, retirement must not create or destroy any
// acquire synchronization (the submissions own and destroy it).
void TestShutdownWithoutPending() {
  PresenterModel model;
  model.RefsFinished();
  const uint32_t newly_failed = model.RetireAndReplace();

  Check("no replacement when nothing is pending", newly_failed == 0);
  Check("no synchronization operations when nothing is pending", model.dispatch.events.empty());
}

}  // namespace

int main() {
  TestPendingSlotIsReplaced();
  TestDelayedSignalingIsIrrelevant();
  TestUntouchedSlotsUnchanged();
  TestSemaphoreCreationFailure();
  TestFenceCreationFailure();
  TestShutdownWithoutPending();

  if (failures != 0) {
    std::printf("\n%d check(s) FAILED\n", failures);
    return 1;
  }
  std::printf("\nAll acquire-sync recovery checks passed\n");
  return 0;
}
