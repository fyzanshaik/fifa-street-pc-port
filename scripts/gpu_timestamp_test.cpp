// Hardware query smoke test using the packaged Vulkan loader; no window/game.
#include <vulkan/vulkan.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
void Check(VkResult r, const char* call) {
  if (r != VK_SUCCESS) { std::fprintf(stderr,"FAIL %s: %d\n",call,r);std::exit(1); }
}
int main() {
  const char* ext="VK_KHR_portability_enumeration";
  VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};app.apiVersion=VK_API_VERSION_1_1;
  VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};ci.pApplicationInfo=&app;
  ci.flags=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;ci.enabledExtensionCount=1;ci.ppEnabledExtensionNames=&ext;
  VkInstance instance;Check(vkCreateInstance(&ci,nullptr,&instance),"instance");
  uint32_t count=0;Check(vkEnumeratePhysicalDevices(instance,&count,nullptr),"devices");
  if (!count) return 2;
  std::vector<VkPhysicalDevice> devices(count);Check(vkEnumeratePhysicalDevices(instance,&count,devices.data()),"devices");
  auto physical=devices[0];VkPhysicalDeviceProperties properties;vkGetPhysicalDeviceProperties(physical,&properties);
  vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,nullptr);
  std::vector<VkQueueFamilyProperties> families(count);vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,families.data());
  uint32_t family=0;while(family<count && !(families[family].queueFlags&VK_QUEUE_GRAPHICS_BIT))++family;
  if (family==count || !families[family].timestampValidBits) {std::puts("UNSUPPORTED GPU timestamp queries");return 2;}
  float priority=1;VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
  qi.queueFamilyIndex=family;qi.queueCount=1;qi.pQueuePriorities=&priority;
  const char* subset="VK_KHR_portability_subset";
  VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};di.queueCreateInfoCount=1;di.pQueueCreateInfos=&qi;
  di.enabledExtensionCount=1;di.ppEnabledExtensionNames=&subset;
  VkDevice device;Check(vkCreateDevice(physical,&di,nullptr,&device),"device");
  VkQueue queue;vkGetDeviceQueue(device,family,0,&queue);
  VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};bi.size=2*1024*1024;bi.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;
  VkBuffer buffer;Check(vkCreateBuffer(device,&bi,nullptr,&buffer),"buffer");
  VkMemoryRequirements req;vkGetBufferMemoryRequirements(device,buffer,&req);
  uint32_t type=0;while(!(req.memoryTypeBits&(1u<<type)))++type;
  VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};ai.allocationSize=req.size;ai.memoryTypeIndex=type;
  VkDeviceMemory memory;Check(vkAllocateMemory(device,&ai,nullptr,&memory),"memory");
  Check(vkBindBufferMemory(device,buffer,memory,0),"bind");
  VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};pi.queueFamilyIndex=family;
  VkCommandPool pool;Check(vkCreateCommandPool(device,&pi,nullptr,&pool),"pool");
  VkCommandBufferAllocateInfo cai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
  cai.commandPool=pool;cai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;cai.commandBufferCount=1;
  VkCommandBuffer command;Check(vkAllocateCommandBuffers(device,&cai,&command),"command");
  VkQueryPoolCreateInfo queryinfo{VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO};queryinfo.queryType=VK_QUERY_TYPE_TIMESTAMP;queryinfo.queryCount=2;
  VkQueryPool query;Check(vkCreateQueryPool(device,&queryinfo,nullptr,&query),"query pool");
  VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};Check(vkBeginCommandBuffer(command,&begin),"begin");
  vkCmdResetQueryPool(command,query,0,2);vkCmdWriteTimestamp(command,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,query,0);
  vkCmdFillBuffer(command,buffer,0,VK_WHOLE_SIZE,0x12345678);
  vkCmdWriteTimestamp(command,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,query,1);Check(vkEndCommandBuffer(command),"end");
  VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};VkFence fence;Check(vkCreateFence(device,&fi,nullptr,&fence),"fence");
  VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.commandBufferCount=1;submit.pCommandBuffers=&command;
  const auto start=std::chrono::steady_clock::now();Check(vkQueueSubmit(queue,1,&submit,fence),"submit");
  Check(vkWaitForFences(device,1,&fence,VK_TRUE,5000000000ull),"bounded wait");
  uint64_t stamps[2];Check(vkGetQueryPoolResults(device,query,0,2,sizeof(stamps),stamps,sizeof(uint64_t),VK_QUERY_RESULT_64_BIT),"nonwaiting query");
  const auto bits=families[family].timestampValidBits;
  const auto mask=bits>=64?UINT64_MAX:((uint64_t(1)<<bits)-1);
  const double gpu_ns=double((stamps[1]-stamps[0])&mask)*properties.limits.timestampPeriod;
  const double wall_ns=std::chrono::duration<double,std::nano>(std::chrono::steady_clock::now()-start).count();
  if (!(gpu_ns>0 && gpu_ns<=wall_ns*1.1)) {std::fprintf(stderr,"FAIL GPU span %.0f vs host %.0f ns\n",gpu_ns,wall_ns);return 1;}
  std::printf("PASS packaged GPU queries: %s, bits=%u period_ns=%.3f GPU_ms=%.6f host_submit_to_read_ms=%.6f\n",
      properties.deviceName,bits,properties.limits.timestampPeriod,gpu_ns/1e6,wall_ns/1e6);
  vkDestroyFence(device,fence,nullptr);vkDestroyQueryPool(device,query,nullptr);
  vkDestroyCommandPool(device,pool,nullptr);vkDestroyBuffer(device,buffer,nullptr);vkFreeMemory(device,memory,nullptr);
  vkDestroyDevice(device,nullptr);vkDestroyInstance(instance,nullptr);
}
