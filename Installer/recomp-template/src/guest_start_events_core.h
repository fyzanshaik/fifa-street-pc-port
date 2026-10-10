// Guest startup-ordering fix for the recompiled FIFA Street worker thread.
//
// sub_820509A8 (the guest "Start" routine) spawns its worker thread via
// sub_82105948 and only afterwards constructs the two CEvent objects at
// this+0x4C / this+0x50 that the worker signals on entry. The guest itself has
// a create-before-initialise race: the two constructions are not synchronised
// with the worker, and Xbox 360 is multicore, so the original guest does not
// guarantee the creating thread reaches them first. The host scheduler simply
// exposes the race far more often. When it loses, the worker runs inside
// XThread::Create(), reaches the signal path (sub_82050928) and reads the still
// NULL +0x4C / +0x50 pointers -> guest read of address 0x4.
//
// This is a host-concurrency correction, not unmodified Xbox semantics: the
// guest code is left byte-for-byte intact and its own instructions still
// construct the events and drive the wait. A codegen [[midasm_hook]] in
// config/default_overrides.toml calls the helpers below inside sub_820509A8:
// ReStreetHoistStartEvents runs immediately before the spawn argument setup
// (guest 0x82050A00) and constructs both events early, and
// ReStreetStartEventsHoisted runs at the original construction site (guest
// 0x82050A7C) to skip it so the early wrappers are not overwritten and leaked.
// No runtime scheduler, guard, fake success or timeout is involved.
//
// This header is deliberately free of any ReXGlue/runtime dependency: the real
// binding lives in guest_start_events.cpp and drives the guest memory and the
// recompiled allocator/constructor, while test/guest_start_events_test.cpp
// drives the same logic with an injected guest allocator, constructor and base
// memory. See docs/BUILDING-MACOS.md, "Guest startup ordering (macOS)" and
// build/macos/logs/startup-order-fix.summary.txt.

#pragma once

#include <cstdint>

namespace restreet::start_events {

// Guest layout of the worker/start object, taken from the generated
// sub_820509A8:
//   +0x44  thread handle (written after the spawn)
//   +0x4C  CEvent A pointer (waited on by sub_82050820)
//   +0x50  CEvent B pointer (signalled by sub_82050928)
inline constexpr uint32_t kThreadHandleOffset = 0x44;
inline constexpr uint32_t kEventAOffset = 0x4C;
inline constexpr uint32_t kEventBOffset = 0x50;

// Link-register values the original construction call sites used, so the
// hoisted calls observe the same LR the guest build would. The recompiled
// callees save LR to their own frame and return natively, so this is fidelity,
// not control flow.
inline constexpr uint32_t kLrAllocA = 0x82050A84;
inline constexpr uint32_t kLrCtorA = 0x82050A90;
inline constexpr uint32_t kLrAllocB = 0x82050AA4;
inline constexpr uint32_t kLrCtorB = 0x82050AB0;

// Host services the hoist needs.
struct Platform {
  void* user;

  // Guest memory access by absolute guest address.
  uint32_t (*read_u32)(void* user, uint32_t guest_address);
  void (*write_u32)(void* user, uint32_t guest_address, uint32_t value);

  // Guest sub_82105CE0(8): allocates an event object and returns its guest
  // pointer, or 0 on allocation failure.
  uint32_t (*alloc_event)(void* user, uint32_t call_site_lr);

  // Guest sub_82050678(ptr): constructs the CEvent in the allocation and
  // returns the handle the guest stores, or 0 on construction failure.
  uint32_t (*construct_event)(void* user, uint32_t alloc, uint32_t call_site_lr);

  // Reports an unrecoverable failure. The production binding logs a fatal
  // diagnostic and terminates the process, so the guest never reaches the
  // spawn; a test binding may throw to observe the failure path.
  void (*fatal)(void* user, uint32_t self, const char* message);
};

// Hoists both event constructions ahead of the worker spawn.
//
// On success both slots (+0x4C, +0x50) are published together and the function
// returns true. On any precondition or allocation/construction failure the
// function reports through `fatal` and returns false without writing either
// slot, so a failure never leaves a half-built object for the spawn to trip on
// and never overwrites a live slot. Callers must not continue to the spawn when
// this returns false; the production binding terminates the process instead.
inline bool HoistStartEvents(const Platform& platform, uint32_t self) {
  // The hook must sit immediately before the spawn, before any of the three
  // fields is set. Anything else means the ordering assumption is broken and
  // hoisting could overwrite a live event or race the already-running worker.
  if (platform.read_u32(platform.user, self + kEventAOffset) != 0 ||
      platform.read_u32(platform.user, self + kEventBOffset) != 0 ||
      platform.read_u32(platform.user, self + kThreadHandleOffset) != 0) {
    platform.fatal(platform.user, self,
                   "precondition failed: event slots or thread handle already set before the "
                   "spawn; refusing to hoist into an unsafe order");
    return false;
  }

  const uint32_t alloc_a = platform.alloc_event(platform.user, kLrAllocA);
  if (alloc_a == 0) {
    platform.fatal(platform.user, self, "guest event allocator returned NULL (event A)");
    return false;
  }
  const uint32_t event_a = platform.construct_event(platform.user, alloc_a, kLrCtorA);
  if (event_a == 0) {
    platform.fatal(platform.user, self, "guest event constructor returned NULL (event A)");
    return false;
  }

  const uint32_t alloc_b = platform.alloc_event(platform.user, kLrAllocB);
  if (alloc_b == 0) {
    platform.fatal(platform.user, self, "guest event allocator returned NULL (event B)");
    return false;
  }
  const uint32_t event_b = platform.construct_event(platform.user, alloc_b, kLrCtorB);
  if (event_b == 0) {
    platform.fatal(platform.user, self, "guest event constructor returned NULL (event B)");
    return false;
  }

  // Both events exist: publish them. A failure above never reaches here, so the
  // successful path writes each slot exactly once and the generated skip then
  // suppresses the original constructions.
  platform.write_u32(platform.user, self + kEventAOffset, event_a);
  platform.write_u32(platform.user, self + kEventBOffset, event_b);
  return true;
}

// True once both events were hoisted. Because HoistStartEvents reports a fatal
// failure (terminating the process in production) rather than returning into
// the spawn, reaching the original construction site with both slots set is
// exactly the successful-hoist state, so the generated skip cannot hide a
// partially built object.
inline bool StartEventsHoisted(const Platform& platform, uint32_t self) {
  return platform.read_u32(platform.user, self + kEventAOffset) != 0 &&
         platform.read_u32(platform.user, self + kEventBOffset) != 0;
}

}  // namespace restreet::start_events
