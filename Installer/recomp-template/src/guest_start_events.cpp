// ReXGlue binding for the macOS guest startup-ordering fix.
//
// The hoist logic (precondition, allocation/construction transaction, fatal
// reporting) lives in guest_start_events_core.h so it can be driven by a
// behavioral test with an injected guest allocator and event constructor. This
// file is the production binding: it reads/writes real guest memory, calls the
// recompiled sub_82105CE0 / sub_82050678 through the existing imported-call API,
// and turns a hoist failure into an explicit fatal diagnostic.
//
// Failure semantics: if the object is not in the expected pre-spawn state, or
// the guest allocator/constructor fails, the hoist reports a fatal diagnostic
// and terminates the process. A compatibility hook cannot reconstruct the
// original guest's OOM behaviour, and returning into the spawn with a
// half-initialised object is the exact crash this fix removes, so we fail
// before the spawn instead of continuing. On abort the OS reclaims the guest
// heap, so the one allocation that may already exist is not leaked into a
// process that keeps running.
//
// Register/LR/r1 preservation: the two nested guest calls run on an isolated
// rex::CallFrame. The frame copies the live values the callees need (r1 stack,
// r13 small-data/TLS base, fpscr) and restores fpscr on scope exit; the outer
// hook context is otherwise untouched, so the guest's live nonvolatiles
// (r29/r30/r31) and the r1 stack pointer are preserved without relying on the
// callee ABI. The callees consume only r3 (= the size / the allocation) and the
// recompiled default module never reads r2, so the frame's otherwise-undefined
// volatile registers are irrelevant. LR is set to each original call site's
// value for fidelity; the recompiled callees save and restore LR inside their
// own frame and return natively, so it never affects control flow.
//
// See docs/BUILDING-MACOS.md, "Guest startup ordering (macOS)" and
// build/macos/logs/startup-order-fix.summary.txt.

#include "guest_start_events_core.h"

#include <cstdint>
#include <cstdlib>

#include <rex/hook.h>
#include <rex/ppc.h>
#include <rex/system/kernel_state.h>
#include <rex/system/thread_state.h>

REX_IMPORT(__imp__sub_82105CE0, ReStreetGuestAlloc, u32(u32));
REX_IMPORT(__imp__sub_82050678, ReStreetGuestEventCtor, u32(u32));

namespace {

namespace se = restreet::start_events;

uint8_t* GuestBase() {
  return rex::system::kernel_state()->memory()->virtual_membase();
}

uint32_t GuestReadU32(void*, uint32_t address) {
  return __builtin_bswap32(*reinterpret_cast<volatile uint32_t*>(GuestBase() + address));
}

void GuestWriteU32(void*, uint32_t address, uint32_t value) {
  *reinterpret_cast<volatile uint32_t*>(GuestBase() + address) = __builtin_bswap32(value);
}

uint32_t GuestAllocEvent(void*, uint32_t call_site_lr) {
  rex::CallFrame frame(*rex::runtime::ThreadState::Get()->context());
  frame.ctx.lr = call_site_lr;
  return ReStreetGuestAlloc(frame, GuestBase(), 8);
}

uint32_t GuestConstructEvent(void*, uint32_t alloc, uint32_t call_site_lr) {
  rex::CallFrame frame(*rex::runtime::ThreadState::Get()->context());
  frame.ctx.lr = call_site_lr;
  return ReStreetGuestEventCtor(frame, GuestBase(), alloc);
}

void HoistFatal(void*, uint32_t self, const char* message) {
  REX_FATAL("ReStreet start-event hoist failed (this={:#010x}): {}", self, message);
}

const se::Platform kPlatform = {
    nullptr,
    GuestReadU32,
    GuestWriteU32,
    GuestAllocEvent,
    GuestConstructEvent,
    HoistFatal,
};

}  // namespace

void ReStreetHoistStartEvents(PPCRegister& r31) {
  if (!se::HoistStartEvents(kPlatform, r31.u32)) {
    // HoistStartEvents reports a fatal diagnostic and terminates the process
    // through its fatal binding before returning false, so this is unreachable
    // in production. The guard stays so that a future non-terminating fatal
    // cannot let the guest spawn with uninitialised events.
    std::abort();
  }
}

bool ReStreetStartEventsHoisted(PPCRegister& r31) {
  return se::StartEventsHoisted(kPlatform, r31.u32);
}
