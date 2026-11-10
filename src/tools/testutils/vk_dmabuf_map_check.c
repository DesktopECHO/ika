/*
 * Checks, for every Vulkan device and each of its host visible memory types,
 * whether another process that mmaps the dma-buf exported from an allocation
 * writes the memory the device then reads. That is how the guest reaches a
 * Venus app's mapped memory: virglrenderer exports the allocation and crosvm
 * maps the dma-buf.
 *
 * A child process fills the dma-buf through mmap, the device copies the buffer
 * to an image and back, and the result is compared page by page.
 *
 * NVIDIA's proprietary driver 620.70.06 fails this for its host visible video
 * memory type (an RTX 4080: type 4, in a 16 MiB block every page from the
 * 592nd on holds the data of the page 16 further on), which is why
 * PATCH.venus-hide-unmappable-video-memory.patch hides that type's host
 * properties from Venus guests. When a driver passes, the patch can go.
 *
 *   cc -O1 -o vk_dmabuf_map_check vk_dmabuf_map_check.c -ldl
 *   ./vk_dmabuf_map_check [MiB per allocation, default 16]
 *
 * Exit status 1 when a memory type maps wrongly.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define WIDTH 2048
#define PAGE_PIXELS 1024 /* a 4 KiB page of 32-bit pixels */
#define MULTIPLIER 2654435761u
#define MULTIPLIER_INVERSE 244002641u /* MULTIPLIER * MULTIPLIER_INVERSE == 1 (mod 2^32) */

static PFN_vkGetInstanceProcAddr get_instance_proc;
static PFN_vkGetDeviceProcAddr get_device_proc;
#define INSTANCE_FN(instance, name) PFN_vk##name name = (PFN_vk##name)get_instance_proc(instance, "vk" #name)
#define DEVICE_FN(device, name) PFN_vk##name name = (PFN_vk##name)get_device_proc(device, "vk" #name)

static uint32_t pixel_value(uint32_t seed, uint32_t index) {
  return seed ^ (index * MULTIPLIER);
}

/* 0: maps correctly, 1: wrong, -1: could not test */
static int check_type(VkDevice device, uint32_t queue_family, const VkPhysicalDeviceMemoryProperties *memory,
                      uint32_t type, VkDeviceSize size) {
  DEVICE_FN(device, CreateBuffer); DEVICE_FN(device, GetBufferMemoryRequirements); DEVICE_FN(device, AllocateMemory);
  DEVICE_FN(device, BindBufferMemory); DEVICE_FN(device, GetMemoryFdKHR); DEVICE_FN(device, MapMemory);
  DEVICE_FN(device, CreateImage); DEVICE_FN(device, GetImageMemoryRequirements); DEVICE_FN(device, BindImageMemory);
  DEVICE_FN(device, CreateCommandPool); DEVICE_FN(device, AllocateCommandBuffers); DEVICE_FN(device, BeginCommandBuffer);
  DEVICE_FN(device, CmdPipelineBarrier); DEVICE_FN(device, CmdCopyBufferToImage); DEVICE_FN(device, CmdCopyImageToBuffer);
  DEVICE_FN(device, EndCommandBuffer); DEVICE_FN(device, GetDeviceQueue); DEVICE_FN(device, QueueSubmit);
  DEVICE_FN(device, CreateFence); DEVICE_FN(device, WaitForFences); DEVICE_FN(device, FreeMemory);
  DEVICE_FN(device, DestroyBuffer); DEVICE_FN(device, DestroyImage); DEVICE_FN(device, DestroyFence);
  DEVICE_FN(device, DestroyCommandPool);

  const uint32_t height = (uint32_t)(size / 4 / WIDTH), pixels = WIDTH * height;
  int result = -1;
  VkBuffer source = VK_NULL_HANDLE, readback = VK_NULL_HANDLE;
  VkDeviceMemory source_memory = VK_NULL_HANDLE, readback_memory = VK_NULL_HANDLE, image_memory = VK_NULL_HANDLE;
  VkImage image = VK_NULL_HANDLE;
  VkCommandPool pool = VK_NULL_HANDLE;
  VkFence fence = VK_NULL_HANDLE;
  int fd = -1;

  /* the buffer under test: exported, as virglrenderer allocates host visible memory */
  const VkExternalMemoryBufferCreateInfo external_buffer = {
      .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
      .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT};
  const VkBufferCreateInfo source_info = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .pNext = &external_buffer,
                                          .size = size, .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT};
  if (CreateBuffer(device, &source_info, NULL, &source)) goto out;
  VkMemoryRequirements source_reqs;
  GetBufferMemoryRequirements(device, source, &source_reqs);
  if (!(source_reqs.memoryTypeBits & (1u << type))) { printf("not usable for buffers\n"); goto out; }
  const VkExportMemoryAllocateInfo export_info = {.sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
                                                  .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT};
  const VkMemoryAllocateInfo source_alloc = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &export_info,
                                             .allocationSize = source_reqs.size, .memoryTypeIndex = type};
  if (AllocateMemory(device, &source_alloc, NULL, &source_memory)) { printf("cannot allocate exportable memory\n"); goto out; }
  if (BindBufferMemory(device, source, source_memory, 0)) goto out;
  const VkMemoryGetFdInfoKHR get_fd = {.sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR, .memory = source_memory,
                                       .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT};
  if (GetMemoryFdKHR(device, &get_fd, &fd)) { printf("cannot export a dma-buf\n"); goto out; }

  /* the readback buffer, mapped by Vulkan itself; system memory where there is any */
  const VkBufferCreateInfo readback_info = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
                                            .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
  if (CreateBuffer(device, &readback_info, NULL, &readback)) goto out;
  VkMemoryRequirements readback_reqs;
  GetBufferMemoryRequirements(device, readback, &readback_reqs);
  int readback_type = -1;
  for (uint32_t t = 0; t < memory->memoryTypeCount; t++) {
    if (!(readback_reqs.memoryTypeBits & (1u << t)) || !(memory->memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))
      continue;
    const int system_memory = !(memory->memoryHeaps[memory->memoryTypes[t].heapIndex].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT);
    if (readback_type < 0 || system_memory) readback_type = (int)t;
    if (system_memory) break;
  }
  if (readback_type < 0) goto out;
  const VkMemoryAllocateInfo readback_alloc = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                               .allocationSize = readback_reqs.size, .memoryTypeIndex = (uint32_t)readback_type};
  uint32_t *read;
  if (AllocateMemory(device, &readback_alloc, NULL, &readback_memory) || BindBufferMemory(device, readback, readback_memory, 0) ||
      MapMemory(device, readback_memory, 0, size, 0, (void **)&read))
    goto out;

  /* the image in between */
  const VkImageCreateInfo image_info = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
      .extent = {WIDTH, height, 1}, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
      .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT};
  if (CreateImage(device, &image_info, NULL, &image)) goto out;
  VkMemoryRequirements image_reqs;
  GetImageMemoryRequirements(device, image, &image_reqs);
  uint32_t image_type = (uint32_t)__builtin_ctz(image_reqs.memoryTypeBits);
  for (uint32_t t = 0; t < memory->memoryTypeCount; t++)
    if ((image_reqs.memoryTypeBits & (1u << t)) && (memory->memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
      image_type = t;
      break;
    }
  const VkMemoryAllocateInfo image_alloc = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                            .allocationSize = image_reqs.size, .memoryTypeIndex = image_type};
  if (AllocateMemory(device, &image_alloc, NULL, &image_memory) || BindImageMemory(device, image, image_memory, 0)) goto out;

  /* the other process: only system calls after the fork */
  const uint32_t seed = 0x1000193u * (type + 1);
  fflush(stdout);
  const pid_t child = fork();
  if (child == 0) {
    uint32_t *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) _exit(errno == ENODEV || errno == EINVAL || errno == ENOSYS ? 10 : 11);
    for (uint32_t i = 0; i < pixels; i++) map[i] = pixel_value(seed, i);
    munmap(map, size);
    _exit(0);
  }
  int status;
  if (child < 0 || waitpid(child, &status, 0) < 0) goto out;
  if (!WIFEXITED(status) || WEXITSTATUS(status)) {
    printf("the dma-buf cannot be mapped (%s): a VMM would not map it either\n",
           WIFEXITED(status) ? (WEXITSTATUS(status) == 10 ? "mmap is not supported" : "mmap failed") : "the mapping faulted");
    goto out;
  }

  const VkCommandPoolCreateInfo pool_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = queue_family};
  if (CreateCommandPool(device, &pool_info, NULL, &pool)) goto out;
  const VkCommandBufferAllocateInfo commands_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
                                                     .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
  VkCommandBuffer commands;
  if (AllocateCommandBuffers(device, &commands_info, &commands)) goto out;
  const VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
  if (BeginCommandBuffer(commands, &begin)) goto out;
  VkImageMemoryBarrier barrier = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = image,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
  CmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
  const VkBufferImageCopy region = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {WIDTH, height, 1}};
  CmdCopyBufferToImage(commands, source, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
  barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
  barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
  CmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
  CmdCopyImageToBuffer(commands, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &region);
  if (EndCommandBuffer(commands)) goto out;
  VkQueue queue;
  GetDeviceQueue(device, queue_family, 0, &queue);
  const VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  if (CreateFence(device, &fence_info, NULL, &fence)) goto out;
  const VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &commands};
  if (QueueSubmit(queue, 1, &submit, fence) || WaitForFences(device, 1, &fence, VK_TRUE, 10000000000ull)) {
    printf("the copy on the device failed\n");
    goto out;
  }

  /* each page: right, zero, the data written to another page, or something else */
  uint32_t pages = pixels / PAGE_PIXELS, right = 0, zero = 0, moved = 0, other = 0, first_wrong = 0, first_holds = 0;
  for (uint32_t page = 0; page < pages; page++) {
    const uint32_t *got = read + page * PAGE_PIXELS, base = page * PAGE_PIXELS;
    uint32_t matching = 0, zeros = 0;
    for (uint32_t i = 0; i < PAGE_PIXELS; i++) {
      matching += got[i] == pixel_value(seed, base + i);
      zeros += got[i] == 0;
    }
    if (matching == PAGE_PIXELS) { right++; continue; }
    const uint32_t from = (got[0] ^ seed) * MULTIPLIER_INVERSE;
    const int is_moved = from < pixels && from % PAGE_PIXELS == 0 && got[PAGE_PIXELS - 1] == pixel_value(seed, from + PAGE_PIXELS - 1);
    if (!(zero + moved + other)) { first_wrong = page; first_holds = is_moved ? from / PAGE_PIXELS : UINT32_MAX; }
    if (zeros == PAGE_PIXELS) zero++;
    else if (is_moved) moved++;
    else other++;
  }
  if (right == pages) {
    printf("ok\n");
    result = 0;
  } else {
    printf("WRONG: of %u pages %u right, %u hold another page's data, %u zero, %u other", pages, right, moved, zero, other);
    if (first_holds != UINT32_MAX) printf("; first: page %u holds what was written to page %u", first_wrong, first_holds);
    else printf("; first wrong page: %u", first_wrong);
    printf("\n");
    result = 1;
  }

out:
  if (fence) DestroyFence(device, fence, NULL);
  if (pool) DestroyCommandPool(device, pool, NULL);
  if (image) DestroyImage(device, image, NULL);
  if (image_memory) FreeMemory(device, image_memory, NULL);
  if (readback) DestroyBuffer(device, readback, NULL);
  if (readback_memory) FreeMemory(device, readback_memory, NULL);
  if (source) DestroyBuffer(device, source, NULL);
  if (source_memory) FreeMemory(device, source_memory, NULL);
  if (fd >= 0) close(fd);
  return result;
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);
  const VkDeviceSize size = (VkDeviceSize)(argc > 1 ? atoi(argv[1]) : 16) << 20;
  if (size < (1u << 20)) { fprintf(stderr, "usage: %s [MiB per allocation, default 16]\n", argv[0]); return 2; }

  void *loader = dlopen("libvulkan.so.1", RTLD_NOW);
  if (!loader) { fprintf(stderr, "no Vulkan loader: %s\n", dlerror()); return 2; }
  get_instance_proc = (PFN_vkGetInstanceProcAddr)dlsym(loader, "vkGetInstanceProcAddr");
  const VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vk_dmabuf_map_check",
                                 .apiVersion = VK_API_VERSION_1_1};
  const VkInstanceCreateInfo instance_info = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
  VkInstance instance;
  if (((PFN_vkCreateInstance)get_instance_proc(NULL, "vkCreateInstance"))(&instance_info, NULL, &instance)) {
    fprintf(stderr, "no Vulkan instance\n");
    return 2;
  }
  INSTANCE_FN(instance, EnumeratePhysicalDevices); INSTANCE_FN(instance, GetPhysicalDeviceProperties);
  INSTANCE_FN(instance, GetPhysicalDeviceMemoryProperties); INSTANCE_FN(instance, GetPhysicalDeviceQueueFamilyProperties);
  INSTANCE_FN(instance, EnumerateDeviceExtensionProperties); INSTANCE_FN(instance, CreateDevice);
  get_device_proc = (PFN_vkGetDeviceProcAddr)get_instance_proc(instance, "vkGetDeviceProcAddr");

  uint32_t device_count = 16;
  VkPhysicalDevice physical_devices[16];
  EnumeratePhysicalDevices(instance, &device_count, physical_devices);
  int wrong = 0;
  for (uint32_t d = 0; d < device_count; d++) {
    VkPhysicalDeviceProperties properties;
    GetPhysicalDeviceProperties(physical_devices[d], &properties);
    printf("%s\n", properties.deviceName);

    uint32_t extension_count = 0;
    EnumerateDeviceExtensionProperties(physical_devices[d], NULL, &extension_count, NULL);
    VkExtensionProperties *extensions = calloc(extension_count ? extension_count : 1, sizeof(*extensions));
    EnumerateDeviceExtensionProperties(physical_devices[d], NULL, &extension_count, extensions);
    int has_fd = 0, has_dma_buf = 0;
    for (uint32_t i = 0; i < extension_count; i++) {
      has_fd |= !strcmp(extensions[i].extensionName, "VK_KHR_external_memory_fd");
      has_dma_buf |= !strcmp(extensions[i].extensionName, "VK_EXT_external_memory_dma_buf");
    }
    free(extensions);
    if (!has_fd || !has_dma_buf) { printf("  no dma-buf export\n"); continue; }

    uint32_t family_count = 16, queue_family = UINT32_MAX;
    VkQueueFamilyProperties families[16];
    GetPhysicalDeviceQueueFamilyProperties(physical_devices[d], &family_count, families);
    for (uint32_t i = 0; i < family_count && queue_family == UINT32_MAX; i++)
      if (families[i].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_TRANSFER_BIT)) queue_family = i;
    if (queue_family == UINT32_MAX) continue;
    const float priority = 1;
    const VkDeviceQueueCreateInfo queue_info = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = queue_family,
                                                .queueCount = 1, .pQueuePriorities = &priority};
    const char *const enabled[] = {"VK_KHR_external_memory_fd", "VK_EXT_external_memory_dma_buf"};
    const VkDeviceCreateInfo device_info = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
                                            .pQueueCreateInfos = &queue_info, .enabledExtensionCount = 2,
                                            .ppEnabledExtensionNames = enabled};
    VkDevice device;
    if (CreateDevice(physical_devices[d], &device_info, NULL, &device)) { printf("  no device\n"); continue; }

    VkPhysicalDeviceMemoryProperties memory;
    GetPhysicalDeviceMemoryProperties(physical_devices[d], &memory);
    for (uint32_t type = 0; type < memory.memoryTypeCount; type++) {
      if (!(memory.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) continue;
      const int video = !!(memory.memoryHeaps[memory.memoryTypes[type].heapIndex].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT);
      printf("  memory type %u (%s heap, flags 0x%x): ", type, video ? "device-local" : "system", memory.memoryTypes[type].propertyFlags);
      wrong |= check_type(device, queue_family, &memory, type, size) == 1;
    }
    DEVICE_FN(device, DestroyDevice);
    DestroyDevice(device, NULL);
  }
  return wrong;
}
