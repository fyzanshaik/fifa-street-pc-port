// Behavioral test for the macOS guest startup-ordering hoist.
//
// Drives the real HoistStartEvents/StartEventsHoisted logic from
// src/guest_start_events_core.h with an injected guest allocator, event
// constructor and base memory (no ReXGlue, no generated guest code). The
// injected fatal throws, which stands in for the production binding's
// terminate-on-failure, so the test observes exactly the state the helper leaves
// behind at the moment it gives up.
//
// Covered:
//   * normal case constructs exactly two events, publishes both slots, and the
//     generated skip then suppresses the original constructions (no double
//     allocation);
//   * first/second allocator failure, first/second constructor failure and an
//     unexpected precondition all route through fatal and publish neither slot;
//   * no failure path overwrites a live slot or leaves a partial object.
//
// Build/run: scripts/test-macos-startup-hook.sh (header-only, clang++).

#include "../src/guest_start_events_core.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace se = restreet::start_events;

namespace {

int g_failures = 0;

#define CHECK(cond)                                               \
  do {                                                            \
    if (!(cond)) {                                                \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      ++g_failures;                                               \
    }                                                             \
  } while (0)

// Minimal guest address space plus counters for the injected guest services.
struct World {
  static constexpr uint32_t kBase = 0x1000;

  std::vector<uint8_t> memory = std::vector<uint8_t>(0x1000, 0);
  uint32_t next_alloc = 0x200;  // first guest pointer handed out
  int alloc_calls = 0;
  int ctor_calls = 0;
  int fatal_calls = 0;
  std::string last_fatal;
  int alloc_fail_on_call = -1;  // 1-based call that returns 0, else -1
  int ctor_fail_on_call = -1;

  uint32_t read(uint32_t address) const {
    uint32_t value = 0;
    std::memcpy(&value, memory.data() + (address - kBase), sizeof(value));
    return value;
  }

  void write(uint32_t address, uint32_t value) {
    std::memcpy(memory.data() + (address - kBase), &value, sizeof(value));
  }
};

// Stands in for the production fatal, which logs and aborts. Throwing lets the
// test prove the helper stops at the failure instead of falling through.
struct FatalAbort {
  std::string message;
};

uint32_t ReadU32(void* user, uint32_t address) {
  return static_cast<World*>(user)->read(address);
}

void WriteU32(void* user, uint32_t address, uint32_t value) {
  static_cast<World*>(user)->write(address, value);
}

uint32_t AllocEvent(void* user, uint32_t /*call_site_lr*/) {
  World* world = static_cast<World*>(user);
  ++world->alloc_calls;
  if (world->alloc_fail_on_call == world->alloc_calls) {
    return 0;
  }
  return world->next_alloc++;  // distinct, non-zero guest pointer
}

uint32_t ConstructEvent(void* user, uint32_t alloc, uint32_t /*call_site_lr*/) {
  World* world = static_cast<World*>(user);
  ++world->ctor_calls;
  if (world->ctor_fail_on_call == world->ctor_calls) {
    return 0;
  }
  return alloc;
}

void Fatal(void* user, uint32_t /*self*/, const char* message) {
  World* world = static_cast<World*>(user);
  ++world->fatal_calls;
  world->last_fatal = message;
  throw FatalAbort{message};
}

se::Platform MakePlatform(World& world) {
  return se::Platform{&world, ReadU32, WriteU32, AllocEvent, ConstructEvent, Fatal};
}

// Arbitrary guest object base; slots at +0x44/+0x4C/+0x50 stay inside memory.
constexpr uint32_t kObject = World::kBase + 0x40;

// Returns true when the hoist completed; false when it reported a fatal.
bool RunHoist(World& world, uint32_t self) {
  try {
    return se::HoistStartEvents(MakePlatform(world), self);
  } catch (const FatalAbort&) {
    return false;
  }
}

}  // namespace

int main() {
  // 1. Normal: exactly two events, both slots published, thread handle left
  //    alone, and the generated skip suppresses the original constructions.
  {
    World world;
    CHECK(RunHoist(world, kObject));
    CHECK(world.fatal_calls == 0);
    CHECK(world.alloc_calls == 2);
    CHECK(world.ctor_calls == 2);
    CHECK(world.read(kObject + se::kEventAOffset) != 0);
    CHECK(world.read(kObject + se::kEventBOffset) != 0);
    CHECK(world.read(kObject + se::kEventAOffset) !=
          world.read(kObject + se::kEventBOffset));
    CHECK(world.read(kObject + se::kThreadHandleOffset) == 0);

    // Mirror the generated site: when the hoist is complete the guest jumps
    // over the original allocations, so no third allocation happens.
    if (!se::StartEventsHoisted(MakePlatform(world), kObject)) {
      AllocEvent(&world, 0);
      ConstructEvent(&world, 0, 0);
    }
    CHECK(world.alloc_calls == 2);
    CHECK(world.ctor_calls == 2);
  }

  // 2. First allocation fails: fatal, nothing published, constructor not run.
  {
    World world;
    world.alloc_fail_on_call = 1;
    CHECK(!RunHoist(world, kObject));
    CHECK(world.fatal_calls == 1);
    CHECK(world.ctor_calls == 0);
    CHECK(world.read(kObject + se::kEventAOffset) == 0);
    CHECK(world.read(kObject + se::kEventBOffset) == 0);
  }

  // 3. Second allocation fails: fatal, event A is held (not published), so the
  //    guest never sees a partial object to overwrite or leak.
  {
    World world;
    world.alloc_fail_on_call = 2;
    CHECK(!RunHoist(world, kObject));
    CHECK(world.fatal_calls == 1);
    CHECK(world.ctor_calls == 1);
    CHECK(world.read(kObject + se::kEventAOffset) == 0);
    CHECK(world.read(kObject + se::kEventBOffset) == 0);
  }

  // 4. First constructor yields 0: fatal, nothing published.
  {
    World world;
    world.ctor_fail_on_call = 1;
    CHECK(!RunHoist(world, kObject));
    CHECK(world.fatal_calls == 1);
    CHECK(world.read(kObject + se::kEventAOffset) == 0);
    CHECK(world.read(kObject + se::kEventBOffset) == 0);
  }

  // 5. Second constructor yields 0: fatal, nothing published.
  {
    World world;
    world.ctor_fail_on_call = 2;
    CHECK(!RunHoist(world, kObject));
    CHECK(world.fatal_calls == 1);
    CHECK(world.read(kObject + se::kEventAOffset) == 0);
    CHECK(world.read(kObject + se::kEventBOffset) == 0);
  }

  // 6. Unexpected precondition (event slot already set): fatal, no allocation,
  //    live slot untouched.
  {
    World world;
    world.write(kObject + se::kEventAOffset, 0xDEADBEEFu);
    CHECK(!RunHoist(world, kObject));
    CHECK(world.fatal_calls == 1);
    CHECK(world.alloc_calls == 0);
    CHECK(world.read(kObject + se::kEventAOffset) == 0xDEADBEEFu);
    CHECK(world.read(kObject + se::kEventBOffset) == 0);
  }

  // 7. Unexpected precondition (thread handle already set): fatal, no work.
  {
    World world;
    world.write(kObject + se::kThreadHandleOffset, 1u);
    CHECK(!RunHoist(world, kObject));
    CHECK(world.fatal_calls == 1);
    CHECK(world.alloc_calls == 0);
  }

  if (g_failures == 0) {
    std::printf("All startup-hoist behavioral tests passed\n");
    return 0;
  }
  std::printf("%d check(s) failed\n", g_failures);
  return 1;
}
