// Headless packaged-MoltenVK experiment. No game, device input or window.
// Mirrors the status -> optional bounded poll -> full fence wait policy.
#include <vulkan/vulkan.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <vector>

using Clock = std::chrono::steady_clock;
static void Check(VkResult result, const char* call) {
  if (result != VK_SUCCESS) {
    std::fprintf(stderr, "FAIL %s: VkResult=%d\n", call, result);
    std::exit(1);
  }
}
static double CpuUs() {
  timespec t{};
  if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)) std::exit(2);
  return double(t.tv_sec) * 1e6 + double(t.tv_nsec) / 1000;
}
int main() {
  const char* instance_extensions[] = {VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
  VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion = VK_API_VERSION_1_1;
  VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
  ici.pApplicationInfo = &app; ici.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
  ici.enabledExtensionCount = 1; ici.ppEnabledExtensionNames = instance_extensions;
  VkInstance instance; Check(vkCreateInstance(&ici, nullptr, &instance), "instance");
  uint32_t count = 0; Check(vkEnumeratePhysicalDevices(instance, &count, nullptr), "device count");
  if (!count) return 2;
  std::vector<VkPhysicalDevice> physicals(count);
  Check(vkEnumeratePhysicalDevices(instance, &count, physicals.data()), "devices");
  VkPhysicalDevice physical = physicals[0];
  vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, nullptr);
  std::vector<VkQueueFamilyProperties> families(count);
  vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families.data());
  uint32_t family = 0;
  for (; family < count; ++family) if (families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT) break;
  if (family == count) return 2;
  float priority = 1;
  VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
  qi.queueFamilyIndex = family; qi.queueCount = 1; qi.pQueuePriorities = &priority;
  const char* device_extensions[] = {"VK_KHR_portability_subset"};
  VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
  dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qi;
  dci.enabledExtensionCount = 1; dci.ppEnabledExtensionNames = device_extensions;
  VkDevice device; Check(vkCreateDevice(physical, &dci, nullptr, &device), "device");
  VkQueue queue; vkGetDeviceQueue(device, family, 0, &queue);
  VkPhysicalDeviceProperties props{}; vkGetPhysicalDeviceProperties(physical, &props);
  std::printf("DEVICE %s; headless 4 KiB fills, serial completion; no game FPS claim\n", props.deviceName);
  VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
  bi.size = 4096; bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
  bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
  VkBuffer buffer; Check(vkCreateBuffer(device, &bi, nullptr, &buffer), "buffer");
  VkMemoryRequirements requirements; vkGetBufferMemoryRequirements(device, buffer, &requirements);
  VkPhysicalDeviceMemoryProperties memory_props; vkGetPhysicalDeviceMemoryProperties(physical, &memory_props);
  uint32_t memory_type = 0;
  const VkMemoryPropertyFlags wanted = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
  for (; memory_type < memory_props.memoryTypeCount; ++memory_type)
    if ((requirements.memoryTypeBits & (1u << memory_type)) &&
        (memory_props.memoryTypes[memory_type].propertyFlags & wanted) == wanted) break;
  if (memory_type == memory_props.memoryTypeCount) return 2;
  VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
  ai.allocationSize = requirements.size; ai.memoryTypeIndex = memory_type;
  VkDeviceMemory memory; Check(vkAllocateMemory(device, &ai, nullptr, &memory), "memory");
  Check(vkBindBufferMemory(device, buffer, memory, 0), "bind");
  void* mapped; Check(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped), "map");
  VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pi.queueFamilyIndex = family;
  VkCommandPool pool; Check(vkCreateCommandPool(device, &pi, nullptr, &pool), "pool");
  VkCommandBufferAllocateInfo ca{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
  ca.commandPool = pool; ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount = 1;
  VkCommandBuffer command; Check(vkAllocateCommandBuffers(device, &ca, &command), "command");
  VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  VkFence fence; Check(vkCreateFence(device, &fi, nullptr, &fence), "fence");
  uint32_t sequence = 0;
  auto iteration = [&](int spin_us, std::vector<double>& waits, uint32_t& fallbacks) {
    Check(vkResetCommandPool(device, pool, 0), "pool reset");
    Check(vkResetFences(device, 1, &fence), "fence reset");
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    Check(vkBeginCommandBuffer(command, &begin), "begin");
    const uint32_t pattern = ++sequence;
    vkCmdFillBuffer(command, buffer, 0, bi.size, pattern);
    VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                         0, 1, &barrier, 0, nullptr, 0, nullptr);
    Check(vkEndCommandBuffer(command), "end");
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.commandBufferCount = 1; submit.pCommandBuffers = &command;
    Check(vkQueueSubmit(queue, 1, &submit, fence), "submit");
    const auto start = Clock::now();
    VkResult result = vkGetFenceStatus(device, fence);
    if (result == VK_NOT_READY && spin_us) {
      const auto deadline = start + std::chrono::microseconds(spin_us);
      do { result = vkGetFenceStatus(device, fence); }
      while (result == VK_NOT_READY && Clock::now() < deadline);
    }
    if (result == VK_NOT_READY) {
      ++fallbacks;
      result = vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ull);
    }
    Check(result, "completion wait");
    waits.push_back(std::chrono::duration<double, std::micro>(Clock::now() - start).count());
    // Every GPU-written word must be visible after completion, in both policies.
    const auto* words = static_cast<const uint32_t*>(mapped);
    for (size_t i = 0; i < bi.size / sizeof(uint32_t); ++i)
      if (words[i] != pattern) { std::fprintf(stderr, "FAIL readback pattern\n"); std::exit(1); }
  };
  std::vector<double> warmup; uint32_t ignored = 0;
  for (int i = 0; i < 100; ++i) iteration(0, warmup, ignored);
  for (int round = 0; round < 4; ++round) {
    for (int mode = 0; mode < 2; ++mode) {
      const int spin = ((round + mode) % 2) ? 200 : 0;
      std::vector<double> waits; waits.reserve(1000); uint32_t fallbacks = 0;
      const auto wall_start = Clock::now(); const double cpu_start = CpuUs();
      for (int i = 0; i < 1000; ++i) iteration(spin, waits, fallbacks);
      const double cpu = CpuUs() - cpu_start;
      const double wall = std::chrono::duration<double, std::micro>(Clock::now() - wall_start).count();
      std::sort(waits.begin(), waits.end());
      double sum = 0; for (double v : waits) sum += v;
      std::printf("round=%d spin_us=%d count=%zu wait_mean_us=%.3f wait_median_us=%.3f "
                  "wait_p95_us=%.3f blocking_fallbacks=%u cpu_us_per_op=%.3f wall_us_per_op=%.3f\n",
                  round, spin, waits.size(), sum / waits.size(), waits[waits.size()/2],
                  waits[waits.size()*95/100], fallbacks, cpu/waits.size(), wall/waits.size());
    }
  }
  Check(vkDeviceWaitIdle(device), "idle");
  vkDestroyFence(device, fence, nullptr); vkDestroyCommandPool(device, pool, nullptr);
  vkUnmapMemory(device, memory); vkDestroyBuffer(device, buffer, nullptr);
  vkFreeMemory(device, memory, nullptr); vkDestroyDevice(device, nullptr); vkDestroyInstance(instance, nullptr);
  std::printf("PASS all %u GPU readback patterns, full completion required in both policies\n", sequence);
}
