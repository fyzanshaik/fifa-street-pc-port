// Real packaged MoltenVK swapchain stress test. Own diagnostic window, no game
// assets, input injection, screenshots, ReXGlue, or guest threads.
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static void Check(VkResult result, const char* call) {
  if (result != VK_SUCCESS) {
    std::fprintf(stderr, "FAIL %s: VkResult=%d\n", call, result);
    std::exit(1);
  }
}

int main(int argc, char** argv) {
  if (argc != 3 || (std::strcmp(argv[1], "fifo") && std::strcmp(argv[1], "immediate"))) {
    std::fprintf(stderr, "usage: presentation-stress {fifo|immediate} seconds(1..60)\n");
    return 2;
  }
  const bool fifo = !std::strcmp(argv[1], "fifo");
  const int seconds = std::atoi(argv[2]);
  if (seconds < 1 || seconds > 60) return 2;
  setvbuf(stdout, nullptr, _IOLBF, 0);
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,640,360)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title = @"MoltenVK presentation diagnostic (closes automatically)";
    window.releasedWhenClosed = NO;
    CAMetalLayer* layer = [CAMetalLayer layer];
    window.contentView.wantsLayer = YES;
    window.contentView.layer = layer;
    [window orderFront:nil];
    const char* extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME,
                               VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ci.pApplicationInfo = &app;
    ci.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    ci.enabledExtensionCount = 3; ci.ppEnabledExtensionNames = extensions;
    VkInstance instance; Check(vkCreateInstance(&ci,nullptr,&instance), "instance");
    auto createSurface = reinterpret_cast<PFN_vkCreateMetalSurfaceEXT>(
        vkGetInstanceProcAddr(instance, "vkCreateMetalSurfaceEXT"));
    if (!createSurface) return 2;
    VkMetalSurfaceCreateInfoEXT sci{VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT}; sci.pLayer = layer;
    VkSurfaceKHR surface; Check(createSurface(instance,&sci,nullptr,&surface), "surface");
    uint32_t count = 0; Check(vkEnumeratePhysicalDevices(instance,&count,nullptr), "device count");
    if (!count) return 2;
    std::vector<VkPhysicalDevice> devices(count);
    Check(vkEnumeratePhysicalDevices(instance,&count,devices.data()), "devices");
    auto physical = devices[0];
    vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,nullptr);
    std::vector<VkQueueFamilyProperties> families(count);
    vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,families.data());
    uint32_t family = 0;
    for (; family < count; ++family) {
      VkBool32 present = false;
      Check(vkGetPhysicalDeviceSurfaceSupportKHR(physical,family,surface,&present), "surface support");
      if (present && (families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) break;
    }
    if (family == count) return 2;
    float priority = 1;
    VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qi.queueFamilyIndex = family; qi.queueCount = 1; qi.pQueuePriorities = &priority;
    const char* deviceExtensions[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME, "VK_KHR_portability_subset"};
    VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    di.queueCreateInfoCount = 1; di.pQueueCreateInfos = &qi;
    di.enabledExtensionCount = 2; di.ppEnabledExtensionNames = deviceExtensions;
    VkDevice device; Check(vkCreateDevice(physical,&di,nullptr,&device), "device");
    VkQueue queue; vkGetDeviceQueue(device,family,0,&queue);
    VkSurfaceCapabilitiesKHR caps;
    Check(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical,surface,&caps), "capabilities");
    if (!(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT)) return 2;
    Check(vkGetPhysicalDeviceSurfaceFormatsKHR(physical,surface,&count,nullptr), "format count");
    std::vector<VkSurfaceFormatKHR> formats(count);
    Check(vkGetPhysicalDeviceSurfaceFormatsKHR(physical,surface,&count,formats.data()), "formats");
    if (formats.empty()) return 2;
    auto format = formats[0];
    for (auto f : formats) if (f.format == VK_FORMAT_B8G8R8A8_UNORM) {format=f; break;}
    Check(vkGetPhysicalDeviceSurfacePresentModesKHR(physical,surface,&count,nullptr), "mode count");
    std::vector<VkPresentModeKHR> modes(count);
    Check(vkGetPhysicalDeviceSurfacePresentModesKHR(physical,surface,&count,modes.data()), "modes");
    const auto mode = fifo ? VK_PRESENT_MODE_FIFO_KHR : VK_PRESENT_MODE_IMMEDIATE_KHR;
    bool supported = false; for (auto m : modes) supported |= m == mode;
    if (!supported) return 2;
    VkSwapchainCreateInfoKHR si{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    si.surface = surface; si.minImageCount = std::max(3u,caps.minImageCount);
    if (caps.maxImageCount) si.minImageCount = std::min(si.minImageCount,caps.maxImageCount);
    si.imageFormat = format.format; si.imageColorSpace = format.colorSpace;
    si.imageExtent = caps.currentExtent.width == UINT32_MAX ? VkExtent2D{640,360} : caps.currentExtent;
    si.imageArrayLayers = 1; si.imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    si.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE; si.preTransform = caps.currentTransform;
    si.compositeAlpha = (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
        ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR : VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    si.presentMode = mode; si.clipped = VK_TRUE;
    VkSwapchainKHR swapchain; Check(vkCreateSwapchainKHR(device,&si,nullptr,&swapchain), "swapchain");
    Check(vkGetSwapchainImagesKHR(device,swapchain,&count,nullptr), "image count");
    std::vector<VkImage> images(count);
    Check(vkGetSwapchainImagesKHR(device,swapchain,&count,images.data()), "images");
    std::vector<VkSemaphore> presentSemaphores(count);
    VkSemaphoreCreateInfo semaphoreInfo{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    for (auto& semaphore : presentSemaphores)
      Check(vkCreateSemaphore(device,&semaphoreInfo,nullptr,&semaphore), "present semaphore");
    struct Slot {VkCommandPool pool; VkCommandBuffer command; VkFence done, acquired; VkSemaphore ready;};
    std::array<Slot,3> slots{};
    for (auto& slot : slots) {
      VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pi.queueFamilyIndex = family;
      Check(vkCreateCommandPool(device,&pi,nullptr,&slot.pool), "pool");
      VkCommandBufferAllocateInfo ca{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
      ca.commandPool = slot.pool; ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount = 1;
      Check(vkAllocateCommandBuffers(device,&ca,&slot.command), "command");
      VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; fi.flags = VK_FENCE_CREATE_SIGNALED_BIT;
      Check(vkCreateFence(device,&fi,nullptr,&slot.done), "submission fence");
      fi.flags = 0; Check(vkCreateFence(device,&fi,nullptr,&slot.acquired), "acquire fence");
      Check(vkCreateSemaphore(device,&semaphoreInfo,nullptr,&slot.ready), "acquire semaphore");
    }
    std::printf("START mode=%s submission_env=%s images=%u seconds=%d\n", argv[1],
        getenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS") ?: "inherit", count, seconds);
    const auto start = std::chrono::steady_clock::now();
    uint64_t frames = 0, timeouts = 0;
    while (std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count() < seconds) {
      @autoreleasepool {
        NSEvent* event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast]
                       inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
        [NSApp updateWindows];
        auto& slot = slots[frames % slots.size()];
        Check(vkWaitForFences(device,1,&slot.done,VK_TRUE,5000000000ull), "slot wait");
        uint32_t image;
        VkResult acquired = vkAcquireNextImageKHR(device,swapchain,50000000,slot.ready,
                                                  fifo ? slot.acquired : VK_NULL_HANDLE,&image);
        if (acquired == VK_TIMEOUT || acquired == VK_NOT_READY) {++timeouts; continue;}
        if (acquired != VK_SUBOPTIMAL_KHR) Check(acquired, "acquire");
        if (fifo) {
          Check(vkWaitForFences(device,1,&slot.acquired,VK_TRUE,5000000000ull), "acquire wait");
          Check(vkResetFences(device,1,&slot.acquired), "acquire reset");
        }
        Check(vkResetFences(device,1,&slot.done), "slot reset");
        Check(vkResetCommandPool(device,slot.pool,0), "pool reset");
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        Check(vkBeginCommandBuffer(slot.command,&begin), "begin");
        VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED; barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = images[image]; barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        vkCmdPipelineBarrier(slot.command,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0,0,nullptr,0,nullptr,1,&barrier);
        VkClearColorValue color{{0.05f,0.12f,0.22f,1.0f}};
        vkCmdClearColorImage(slot.command,images[image],VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                             &color,1,&barrier.subresourceRange);
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask = 0;
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        vkCmdPipelineBarrier(slot.command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                             0,0,nullptr,0,nullptr,1,&barrier);
        Check(vkEndCommandBuffer(slot.command), "end");
        VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &slot.ready; submit.pWaitDstStageMask = &stage;
        submit.commandBufferCount = 1; submit.pCommandBuffers = &slot.command;
        submit.signalSemaphoreCount = 1; submit.pSignalSemaphores = &presentSemaphores[image];
        Check(vkQueueSubmit(queue,1,&submit,slot.done), "submit");
        VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR}; present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &presentSemaphores[image]; present.swapchainCount = 1;
        present.pSwapchains = &swapchain; present.pImageIndices = &image;
        VkResult result = vkQueuePresentKHR(queue,&present);
        if (result != VK_SUBOPTIMAL_KHR) Check(result,"present");
        if (++frames % 1000 == 0) std::printf("PROGRESS frames=%llu\n", (unsigned long long)frames);
      }
    }
    Check(vkDeviceWaitIdle(device), "retirement");
    std::printf("PASS frames=%llu timeouts=%llu elapsed_s=%.3f\n", (unsigned long long)frames,
        (unsigned long long)timeouts,std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count());
    for (auto& slot : slots) {
      vkDestroySemaphore(device,slot.ready,nullptr); vkDestroyFence(device,slot.acquired,nullptr);
      vkDestroyFence(device,slot.done,nullptr); vkDestroyCommandPool(device,slot.pool,nullptr);
    }
    for (auto semaphore : presentSemaphores) vkDestroySemaphore(device,semaphore,nullptr);
    vkDestroySwapchainKHR(device,swapchain,nullptr); vkDestroyDevice(device,nullptr);
    vkDestroySurfaceKHR(instance,surface,nullptr); vkDestroyInstance(instance,nullptr);
    [window close]; [window release];
  }
}
