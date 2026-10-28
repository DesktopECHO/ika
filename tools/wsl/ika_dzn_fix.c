/*
 * VK_LAYER_IKA_dzn_fix: works around Mesa Dozen (dzn) bugs that crash
 * gfxstream when Ika runs on WSL2.
 *
 * 1. vkGetPhysicalDeviceImageFormatProperties2 with a
 *    VkPhysicalDeviceExternalImageFormatInfo in the input chain but no
 *    VkExternalImageFormatProperties in the output chain (optional per spec):
 *    dzn writes through a NULL pointer (dzn_device.c, Mesa 26.2.5). The layer
 *    appends a scratch VkExternalImageFormatProperties when the caller has none.
 *
 * 2. ANGLE caps OpenGL ES at 2.0 without VK_EXT_provoking_vertex, which it
 *    needs for GL's last-vertex flat shading. D3D12 has no provoking vertex
 *    control, so dzn lacks the extension and Android apps that need ES 3
 *    (Chromium's GPU process, WebView) fail. The layer advertises the extension
 *    with provokingVertexLast and strips it before dzn sees it: flat varyings
 *    then come from the first vertex, which differs only when a primitive's
 *    vertices carry different flat values.
 *
 * 3. Chromium's Vulkan backend (Chrome, WebView) requires samplerYcbcrConversion,
 *    which dzn lacks. For instances other than gfxstream's own ("AEMU"), the
 *    layer reports the feature, hands out placeholder conversion objects and
 *    drops VkSamplerYcbcrConversionInfo before dzn sees it: sampling then reads
 *    the image as is, without YCbCr-to-RGB conversion. Set IKA_DZN_FAKE_YCBCR=0
 *    to turn this off.
 *
 * 4. gfxstream's ETC2/ASTC decompression creates its output image with the
 *    guest's VkImageFormatListCreateInfo, then writes it through an R8G8B8A8_UINT
 *    storage view the list leaves out. Vulkan forbids that; RADV tolerates it,
 *    but dzn passes the list to D3D12 as castable formats, and the UAV outside it
 *    is an invalid call that removes the D3D12 device (DXGI_ERROR_INVALID_CALL),
 *    taking every Android app's Vulkan with it. For MUTABLE_FORMAT images the
 *    layer drops the format list, which only narrows the formats views may use.
 *
 * 5. gfxstream's ETC2/ASTC emulation allocates memory dedicated to the
 *    decompressed output image (MUTABLE_FORMAT | EXTENDED_USAGE), then binds its
 *    compressed-block images into the same memory. Vulkan forbids binding other
 *    images to a dedicated allocation; dzn implements one as a committed
 *    resource shaped like the dedicated image and reuses that resource for any
 *    image bound to it, so a block image's storage view becomes a UAV whose
 *    format cannot apply to the resource. D3D12 then removes the device
 *    (DXGI_ERROR_INVALID_CALL). For such output images, unless the memory is
 *    imported or exported, the layer drops VkMemoryDedicatedAllocateInfo: dzn
 *    then creates a heap and places each image in it.
 *
 * Diagnostics: with IKA_DZN_TRACE_REMOVAL=1 (and IKA_D3D12_DRED=1 for the
 * libd3d12.so shim), the layer checks after each resource, descriptor and
 * command call whether D3D12 removed the device, and logs the first call
 * after which it had, with its parameters.
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vk_layer.h>
#include <vulkan/vulkan.h>

#define LAYER_NAME "VK_LAYER_IKA_dzn_fix"
#define EXPORT __attribute__((visibility("default")))

typedef void *dispatch_key;
static inline dispatch_key get_key(const void *object) { return *(dispatch_key *)object; }

struct instance_data {
  dispatch_key key;
  VkInstance instance;
  PFN_vkGetInstanceProcAddr gipa;
  PFN_vkDestroyInstance destroy_instance;
  PFN_vkGetPhysicalDeviceImageFormatProperties2 get_image_format_props2;
  PFN_vkGetPhysicalDeviceImageFormatProperties2 get_image_format_props2_khr;
  PFN_vkEnumerateDeviceExtensionProperties enumerate_device_extensions;
  PFN_vkGetPhysicalDeviceFeatures2 get_features2;
  PFN_vkGetPhysicalDeviceFeatures2 get_features2_khr;
  PFN_vkGetPhysicalDeviceProperties2 get_properties2;
  PFN_vkGetPhysicalDeviceProperties2 get_properties2_khr;
  int fake_ycbcr;
  struct instance_data *next;
};

static const VkExtensionProperties provoking_vertex_ext = {VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME,
                                                           VK_EXT_PROVOKING_VERTEX_SPEC_VERSION};

struct device_data {
  dispatch_key key;
  PFN_vkGetDeviceProcAddr gdpa;
  PFN_vkDestroyDevice destroy_device;
  PFN_vkCreateImage create_image_next;
  PFN_vkDestroyImage destroy_image_next;
  PFN_vkAllocateMemory allocate_memory_next;
  int fake_ycbcr;
  PFN_vkCreateSampler create_sampler;
  PFN_vkCreateImageView create_image_view;
  /* IKA_DZN_TRACE_REMOVAL */
  PFN_vkCreateImage create_image;
  PFN_vkCreateBufferView create_buffer_view;
  PFN_vkUpdateDescriptorSets update_descriptor_sets;
  PFN_vkAllocateMemory allocate_memory;
  PFN_vkBindImageMemory bind_image_memory;
  PFN_vkCreateComputePipelines create_compute_pipelines;
  PFN_vkCmdDispatch cmd_dispatch;
  PFN_vkCmdCopyBufferToImage cmd_copy_buffer_to_image;
  PFN_vkCmdPipelineBarrier cmd_pipeline_barrier;
  PFN_vkQueueSubmit queue_submit;
  struct device_data *next;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct instance_data *instances;
static struct device_data *devices;

static struct instance_data *find_instance(const void *object) {
  dispatch_key key = get_key(object);
  pthread_mutex_lock(&lock);
  struct instance_data *data = instances;
  while (data && data->key != key) data = data->next;
  pthread_mutex_unlock(&lock);
  return data;
}

static struct device_data *find_device(const void *object) {
  dispatch_key key = get_key(object);
  pthread_mutex_lock(&lock);
  struct device_data *data = devices;
  while (data && data->key != key) data = data->next;
  pthread_mutex_unlock(&lock);
  return data;
}

static VkResult fixed_image_format_props2(PFN_vkGetPhysicalDeviceImageFormatProperties2 next,
                                          VkPhysicalDevice pdev,
                                          const VkPhysicalDeviceImageFormatInfo2 *info,
                                          VkImageFormatProperties2 *props) {
  int has_external_info = 0;
  for (const VkBaseInStructure *s = info->pNext; s; s = s->pNext) {
    if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO) has_external_info = 1;
  }
  if (!has_external_info) return next(pdev, info, props);

  VkBaseOutStructure *last = (VkBaseOutStructure *)props;
  for (VkBaseOutStructure *s = props->pNext; s; s = s->pNext) {
    if (s->sType == VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES) return next(pdev, info, props);
    last = s;
  }

  VkExternalImageFormatProperties scratch = {
      .sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
  };
  last->pNext = (VkBaseOutStructure *)&scratch;
  VkResult result = next(pdev, info, props);
  last->pNext = NULL;
  return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_GetPhysicalDeviceImageFormatProperties2(
    VkPhysicalDevice pdev, const VkPhysicalDeviceImageFormatInfo2 *info, VkImageFormatProperties2 *props) {
  struct instance_data *data = find_instance(pdev);
  return fixed_image_format_props2(data->get_image_format_props2, pdev, info, props);
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_GetPhysicalDeviceImageFormatProperties2KHR(
    VkPhysicalDevice pdev, const VkPhysicalDeviceImageFormatInfo2 *info, VkImageFormatProperties2 *props) {
  struct instance_data *data = find_instance(pdev);
  return fixed_image_format_props2(data->get_image_format_props2_khr, pdev, info, props);
}

/* Unlinks every struct of the given type from a pNext chain; restore_chain() puts them back. */
#define MAX_UNLINKED 4
struct unlinked {
  VkBaseOutStructure *prev, *removed;
};

static int unlink_structs(void *head, VkStructureType type, struct unlinked *out) {
  int n = 0;
  for (VkBaseOutStructure *prev = head; prev->pNext && n < MAX_UNLINKED;) {
    if (prev->pNext->sType == type) {
      out[n].prev = prev;
      out[n].removed = prev->pNext;
      prev->pNext = prev->pNext->pNext;
      n++;
    } else {
      prev = prev->pNext;
    }
  }
  return n;
}

static void restore_chain(struct unlinked *list, int n) {
  for (int i = n - 1; i >= 0; i--) list[i].prev->pNext = list[i].removed;
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_EnumerateDeviceExtensionProperties(VkPhysicalDevice pdev,
                                                                             const char *layer_name,
                                                                             uint32_t *count,
                                                                             VkExtensionProperties *props) {
  if (layer_name && !strcmp(layer_name, LAYER_NAME)) {
    *count = 0;
    return VK_SUCCESS;
  }
  struct instance_data *data = find_instance(pdev);
  if (layer_name) return data->enumerate_device_extensions(pdev, layer_name, count, props);

  uint32_t n = 0;
  VkResult result = data->enumerate_device_extensions(pdev, NULL, &n, NULL);
  if (result != VK_SUCCESS) return result;
  VkExtensionProperties *all = calloc(n + 1, sizeof(*all));
  if (!all) return VK_ERROR_OUT_OF_HOST_MEMORY;
  result = data->enumerate_device_extensions(pdev, NULL, &n, all);
  if (result < 0) {
    free(all);
    return result;
  }
  int present = 0;
  for (uint32_t i = 0; i < n; i++) present |= !strcmp(all[i].extensionName, provoking_vertex_ext.extensionName);
  if (!present) all[n++] = provoking_vertex_ext;

  if (!props) {
    *count = n;
    free(all);
    return VK_SUCCESS;
  }
  uint32_t copied = *count < n ? *count : n;
  memcpy(props, all, copied * sizeof(*props));
  *count = copied;
  free(all);
  return copied < n ? VK_INCOMPLETE : VK_SUCCESS;
}

/* Points at the samplerYcbcrConversion member of a features struct, or NULL. */
static VkBool32 *ycbcr_feature(VkBaseOutStructure *s) {
  if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES)
    return &((VkPhysicalDeviceVulkan11Features *)s)->samplerYcbcrConversion;
  if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES)
    return &((VkPhysicalDeviceSamplerYcbcrConversionFeatures *)s)->samplerYcbcrConversion;
  return NULL;
}

static void fixed_features2(struct instance_data *data, PFN_vkGetPhysicalDeviceFeatures2 next,
                            VkPhysicalDevice pdev, VkPhysicalDeviceFeatures2 *features) {
  struct unlinked removed[MAX_UNLINKED];
  int n = unlink_structs(features, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT, removed);
  next(pdev, features);
  restore_chain(removed, n);
  for (int i = 0; i < n; i++) {
    VkPhysicalDeviceProvokingVertexFeaturesEXT *pv = (VkPhysicalDeviceProvokingVertexFeaturesEXT *)removed[i].removed;
    pv->provokingVertexLast = VK_TRUE;
    pv->transformFeedbackPreservesProvokingVertex = VK_FALSE;
  }
  if (data->fake_ycbcr) {
    for (VkBaseOutStructure *s = features->pNext; s; s = s->pNext) {
      VkBool32 *ycbcr = ycbcr_feature(s);
      if (ycbcr) *ycbcr = VK_TRUE;
    }
  }
}

static VKAPI_ATTR void VKAPI_CALL layer_GetPhysicalDeviceFeatures2(VkPhysicalDevice pdev,
                                                                  VkPhysicalDeviceFeatures2 *features) {
  struct instance_data *data = find_instance(pdev);
  fixed_features2(data, data->get_features2, pdev, features);
}

static VKAPI_ATTR void VKAPI_CALL layer_GetPhysicalDeviceFeatures2KHR(VkPhysicalDevice pdev,
                                                                     VkPhysicalDeviceFeatures2 *features) {
  struct instance_data *data = find_instance(pdev);
  fixed_features2(data, data->get_features2_khr, pdev, features);
}

static void fixed_properties2(PFN_vkGetPhysicalDeviceProperties2 next, VkPhysicalDevice pdev,
                              VkPhysicalDeviceProperties2 *props) {
  struct unlinked removed[MAX_UNLINKED];
  int n = unlink_structs(props, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_PROPERTIES_EXT, removed);
  next(pdev, props);
  restore_chain(removed, n);
  for (int i = 0; i < n; i++) {
    VkPhysicalDeviceProvokingVertexPropertiesEXT *pv =
        (VkPhysicalDeviceProvokingVertexPropertiesEXT *)removed[i].removed;
    pv->provokingVertexModePerPipeline = VK_TRUE;
    pv->transformFeedbackPreservesTriangleFanProvokingVertex = VK_FALSE;
  }
}

static VKAPI_ATTR void VKAPI_CALL layer_GetPhysicalDeviceProperties2(VkPhysicalDevice pdev,
                                                                    VkPhysicalDeviceProperties2 *props) {
  fixed_properties2(find_instance(pdev)->get_properties2, pdev, props);
}

static VKAPI_ATTR void VKAPI_CALL layer_GetPhysicalDeviceProperties2KHR(VkPhysicalDevice pdev,
                                                                       VkPhysicalDeviceProperties2 *props) {
  fixed_properties2(find_instance(pdev)->get_properties2_khr, pdev, props);
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateInstance(const VkInstanceCreateInfo *info,
                                                           const VkAllocationCallbacks *alloc,
                                                           VkInstance *instance) {
  VkLayerInstanceCreateInfo *chain = (VkLayerInstanceCreateInfo *)info->pNext;
  while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO &&
                    chain->function == VK_LAYER_LINK_INFO)) {
    chain = (VkLayerInstanceCreateInfo *)chain->pNext;
  }
  if (!chain) return VK_ERROR_INITIALIZATION_FAILED;

  PFN_vkGetInstanceProcAddr gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
  chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;

  PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
  VkResult result = create(info, alloc, instance);
  if (result != VK_SUCCESS) return result;

  struct instance_data *data = calloc(1, sizeof(*data));
  data->key = get_key(*instance);
  data->instance = *instance;
  data->gipa = gipa;
  data->destroy_instance = (PFN_vkDestroyInstance)gipa(*instance, "vkDestroyInstance");
  data->get_image_format_props2 =
      (PFN_vkGetPhysicalDeviceImageFormatProperties2)gipa(*instance, "vkGetPhysicalDeviceImageFormatProperties2");
  data->get_image_format_props2_khr =
      (PFN_vkGetPhysicalDeviceImageFormatProperties2)gipa(*instance, "vkGetPhysicalDeviceImageFormatProperties2KHR");
  if (!data->get_image_format_props2_khr) data->get_image_format_props2_khr = data->get_image_format_props2;
  data->enumerate_device_extensions =
      (PFN_vkEnumerateDeviceExtensionProperties)gipa(*instance, "vkEnumerateDeviceExtensionProperties");
  data->get_features2 = (PFN_vkGetPhysicalDeviceFeatures2)gipa(*instance, "vkGetPhysicalDeviceFeatures2");
  data->get_features2_khr = (PFN_vkGetPhysicalDeviceFeatures2)gipa(*instance, "vkGetPhysicalDeviceFeatures2KHR");
  if (!data->get_features2_khr) data->get_features2_khr = data->get_features2;
  data->get_properties2 = (PFN_vkGetPhysicalDeviceProperties2)gipa(*instance, "vkGetPhysicalDeviceProperties2");
  data->get_properties2_khr =
      (PFN_vkGetPhysicalDeviceProperties2)gipa(*instance, "vkGetPhysicalDeviceProperties2KHR");
  if (!data->get_properties2_khr) data->get_properties2_khr = data->get_properties2;
  /* gfxstream's own instance is "AEMU"; Android apps' instances carry the app's name. */
  const VkApplicationInfo *app = info->pApplicationInfo;
  const char *fake = getenv("IKA_DZN_FAKE_YCBCR");
  data->fake_ycbcr = app && app->pApplicationName && strcmp(app->pApplicationName, "AEMU") &&
                     !(fake && !strcmp(fake, "0"));

  pthread_mutex_lock(&lock);
  data->next = instances;
  instances = data;
  pthread_mutex_unlock(&lock);
  return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL layer_DestroyInstance(VkInstance instance, const VkAllocationCallbacks *alloc) {
  dispatch_key key = get_key(instance);
  pthread_mutex_lock(&lock);
  struct instance_data **link = &instances, *data;
  while ((data = *link) && data->key != key) link = &data->next;
  if (data) *link = data->next;
  pthread_mutex_unlock(&lock);
  if (!data) return;
  data->destroy_instance(instance, alloc);
  free(data);
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateDevice(VkPhysicalDevice pdev, const VkDeviceCreateInfo *info,
                                                         const VkAllocationCallbacks *alloc, VkDevice *device) {
  VkLayerDeviceCreateInfo *chain = (VkLayerDeviceCreateInfo *)info->pNext;
  while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO &&
                    chain->function == VK_LAYER_LINK_INFO)) {
    chain = (VkLayerDeviceCreateInfo *)chain->pNext;
  }
  if (!chain) return VK_ERROR_INITIALIZATION_FAILED;

  PFN_vkGetInstanceProcAddr gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
  PFN_vkGetDeviceProcAddr gdpa = chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;
  chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;

  struct instance_data *instance = find_instance(pdev);
  PFN_vkCreateDevice create = (PFN_vkCreateDevice)gipa(instance->instance, "vkCreateDevice");

  /* Hide the emulated VK_EXT_provoking_vertex from the driver. */
  VkDeviceCreateInfo fixed = *info;
  const char **names = calloc(info->enabledExtensionCount + 1, sizeof(*names));
  if (!names) return VK_ERROR_OUT_OF_HOST_MEMORY;
  fixed.enabledExtensionCount = 0;
  for (uint32_t i = 0; i < info->enabledExtensionCount; i++) {
    if (strcmp(info->ppEnabledExtensionNames[i], provoking_vertex_ext.extensionName))
      names[fixed.enabledExtensionCount++] = info->ppEnabledExtensionNames[i];
  }
  fixed.ppEnabledExtensionNames = names;
  struct unlinked removed[MAX_UNLINKED];
  int n = unlink_structs(&fixed, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT, removed);
  /* Don't ask dzn for the emulated samplerYcbcrConversion. */
  VkBool32 *ycbcr_enables[MAX_UNLINKED];
  int ycbcr_count = 0;
  if (instance->fake_ycbcr) {
    for (VkBaseOutStructure *s = (VkBaseOutStructure *)fixed.pNext; s && ycbcr_count < MAX_UNLINKED; s = s->pNext) {
      VkBool32 *ycbcr = ycbcr_feature(s);
      if (ycbcr && *ycbcr) {
        *ycbcr = VK_FALSE;
        ycbcr_enables[ycbcr_count++] = ycbcr;
      }
    }
  }
  VkResult result = create(pdev, &fixed, alloc, device);
  for (int i = 0; i < ycbcr_count; i++) *ycbcr_enables[i] = VK_TRUE;
  restore_chain(removed, n);
  free(names);
  if (result != VK_SUCCESS) return result;

  struct device_data *data = calloc(1, sizeof(*data));
  data->key = get_key(*device);
  data->gdpa = gdpa;
  data->destroy_device = (PFN_vkDestroyDevice)gdpa(*device, "vkDestroyDevice");
  data->fake_ycbcr = instance->fake_ycbcr;
  data->create_sampler = (PFN_vkCreateSampler)gdpa(*device, "vkCreateSampler");
  data->create_image_view = (PFN_vkCreateImageView)gdpa(*device, "vkCreateImageView");
  data->create_image = (PFN_vkCreateImage)gdpa(*device, "vkCreateImage");
  data->create_image_next = data->create_image;
  data->destroy_image_next = (PFN_vkDestroyImage)gdpa(*device, "vkDestroyImage");
  data->allocate_memory_next = (PFN_vkAllocateMemory)gdpa(*device, "vkAllocateMemory");
  data->create_buffer_view = (PFN_vkCreateBufferView)gdpa(*device, "vkCreateBufferView");
  data->update_descriptor_sets = (PFN_vkUpdateDescriptorSets)gdpa(*device, "vkUpdateDescriptorSets");
  data->allocate_memory = (PFN_vkAllocateMemory)gdpa(*device, "vkAllocateMemory");
  data->bind_image_memory = (PFN_vkBindImageMemory)gdpa(*device, "vkBindImageMemory");
  data->create_compute_pipelines = (PFN_vkCreateComputePipelines)gdpa(*device, "vkCreateComputePipelines");
  data->cmd_dispatch = (PFN_vkCmdDispatch)gdpa(*device, "vkCmdDispatch");
  data->cmd_copy_buffer_to_image = (PFN_vkCmdCopyBufferToImage)gdpa(*device, "vkCmdCopyBufferToImage");
  data->cmd_pipeline_barrier = (PFN_vkCmdPipelineBarrier)gdpa(*device, "vkCmdPipelineBarrier");
  data->queue_submit = (PFN_vkQueueSubmit)gdpa(*device, "vkQueueSubmit");

  pthread_mutex_lock(&lock);
  data->next = devices;
  devices = data;
  pthread_mutex_unlock(&lock);
  return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL layer_DestroyDevice(VkDevice device, const VkAllocationCallbacks *alloc) {
  dispatch_key key = get_key(device);
  pthread_mutex_lock(&lock);
  struct device_data **link = &devices, *data;
  while ((data = *link) && data->key != key) link = &data->next;
  if (data) *link = data->next;
  pthread_mutex_unlock(&lock);
  if (!data) return;
  data->destroy_device(device, alloc);
  free(data);
}

/* ---- IKA_DZN_TRACE_REMOVAL ---- */

static int tracing(void) {
  static int value = -1;
  if (value < 0) {
    const char *v = getenv("IKA_DZN_TRACE_REMOVAL");
    value = v && v[0] == '1';
  }
  return value;
}

/* ika_d3d12_removed_reason() from the libd3d12.so shim, which dzn loaded RTLD_LOCAL. */
static int removed_reason(void) {
  static int (*fn)(void);
  static int looked_up;
  if (!looked_up) {
    void *shim = dlopen("libd3d12.so", RTLD_NOW | RTLD_NOLOAD);
    if (shim) fn = (int (*)(void))dlsym(shim, "ika_d3d12_removed_reason");
    looked_up = 1;
  }
  return fn ? fn() : 0;
}

struct image_info {
  uint64_t handle;
  VkImageCreateInfo info;
  char chain[160]; /* pNext sTypes, with external handle types and listed formats */
};
#define IMAGE_TABLE_SIZE (1u << 16)
static struct image_info image_table[IMAGE_TABLE_SIZE];
static pthread_mutex_t image_lock = PTHREAD_MUTEX_INITIALIZER;

static void remember_image(VkImage image, const VkImageCreateInfo *info) {
  uint64_t h = (uint64_t)image;
  pthread_mutex_lock(&image_lock);
  for (uint32_t i = 0; i < IMAGE_TABLE_SIZE; i++) {
    struct image_info *e = &image_table[(h / 8 + i) % IMAGE_TABLE_SIZE];
    if (!e->handle || e->handle == h) {
      e->handle = h;
      e->info = *info;
      e->info.pNext = NULL;
      int len = 0;
      e->chain[0] = 0;
      for (const VkBaseInStructure *c = info->pNext; c && len < (int)sizeof(e->chain) - 24; c = c->pNext) {
        len += snprintf(e->chain + len, sizeof(e->chain) - len, " %d", c->sType);
        if (c->sType == VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO)
          len += snprintf(e->chain + len, sizeof(e->chain) - len, "(handles %#x)",
                          ((const VkExternalMemoryImageCreateInfo *)c)->handleTypes);
      }
      break;
    }
  }
  pthread_mutex_unlock(&image_lock);
}

static const char *image_chain(VkImage image);

static const VkImageCreateInfo *find_image(VkImage image) {
  uint64_t h = (uint64_t)image;
  for (uint32_t i = 0; i < IMAGE_TABLE_SIZE; i++) {
    struct image_info *e = &image_table[(h / 8 + i) % IMAGE_TABLE_SIZE];
    if (e->handle == h) return &e->info;
    if (!e->handle) return NULL;
  }
  return NULL;
}

static void describe_image(const char *label, VkImage image) {
  const VkImageCreateInfo *i = find_image(image);
  if (!i) {
    fprintf(stderr, "ika trace:   %s %p: unknown\n", label, (void *)image);
    return;
  }
  fprintf(stderr,
          "ika trace:   %s %p: type %d format %d extent %ux%ux%u mips %u layers %u samples %d tiling %d usage %#x flags %#x\n",
          label, (void *)image, i->imageType, i->format, i->extent.width, i->extent.height, i->extent.depth,
          i->mipLevels, i->arrayLayers, i->samples, i->tiling, i->usage, i->flags);
  fprintf(stderr, "ika trace:   %s pNext:%s\n", label, image_chain(image));
}

static const char *image_chain(VkImage image) {
  uint64_t h = (uint64_t)image;
  for (uint32_t i = 0; i < IMAGE_TABLE_SIZE; i++) {
    struct image_info *e = &image_table[(h / 8 + i) % IMAGE_TABLE_SIZE];
    if (e->handle == h) return e->chain[0] ? e->chain : " (none)";
    if (!e->handle) break;
  }
  return " ?";
}

struct view_info {
  uint64_t handle;
  VkImageViewCreateInfo info;
  VkImageUsageFlags usage;
};
static struct view_info view_table[IMAGE_TABLE_SIZE];

static void remember_view(VkImageView view, const VkImageViewCreateInfo *info) {
  uint64_t h = (uint64_t)view;
  VkImageUsageFlags usage = 0;
  for (const VkBaseInStructure *s = info->pNext; s; s = s->pNext)
    if (s->sType == VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO)
      usage = ((const VkImageViewUsageCreateInfo *)s)->usage;
  pthread_mutex_lock(&image_lock);
  for (uint32_t i = 0; i < IMAGE_TABLE_SIZE; i++) {
    struct view_info *e = &view_table[(h / 8 + i) % IMAGE_TABLE_SIZE];
    if (!e->handle || e->handle == h) {
      e->handle = h;
      e->info = *info;
      e->info.pNext = NULL;
      e->usage = usage;
      break;
    }
  }
  pthread_mutex_unlock(&image_lock);
}

static void describe_view(const char *label, VkImageView view) {
  uint64_t h = (uint64_t)view;
  for (uint32_t i = 0; i < IMAGE_TABLE_SIZE; i++) {
    struct view_info *e = &view_table[(h / 8 + i) % IMAGE_TABLE_SIZE];
    if (e->handle == h) {
      const VkImageViewCreateInfo *v = &e->info;
      fprintf(stderr, "ika trace:   %s %p: view type %d format %d aspect %#x mips %u+%u layers %u+%u usage %#x\n",
              label, (void *)view, v->viewType, v->format, v->subresourceRange.aspectMask,
              v->subresourceRange.baseMipLevel, v->subresourceRange.levelCount, v->subresourceRange.baseArrayLayer,
              v->subresourceRange.layerCount, e->usage);
      describe_image("  of image", v->image);
      return;
    }
    if (!e->handle) break;
  }
  fprintf(stderr, "ika trace:   %s %p: unknown view\n", label, (void *)view);
}

/* Returns 1 the first time the D3D12 device is found removed. */
static int newly_removed(const char *call) {
  static volatile int reported;
  if (reported) return 0;
  int reason = removed_reason();
  if (!reason) return 0;
  reported = 1;
  fprintf(stderr, "ika trace: D3D12 device removed (reason %#x) by or before %s\n", (unsigned)reason, call);
  return 1;
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateImage(VkDevice device, const VkImageCreateInfo *info,
                                                        const VkAllocationCallbacks *alloc, VkImage *image);
static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateImageInner(VkDevice device, const VkImageCreateInfo *info,
                                                             const VkAllocationCallbacks *alloc, VkImage *image);
static VKAPI_ATTR VkResult VKAPI_CALL layer_AllocateMemory(VkDevice device, const VkMemoryAllocateInfo *info,
                                                           const VkAllocationCallbacks *alloc,
                                                           VkDeviceMemory *memory);

static VKAPI_ATTR VkResult VKAPI_CALL trace_CreateImage(VkDevice device, const VkImageCreateInfo *info,
                                                        const VkAllocationCallbacks *alloc, VkImage *image) {
  VkResult result = layer_CreateImage(device, info, alloc, image);
  if (result == VK_SUCCESS) remember_image(*image, info);
  if (newly_removed("vkCreateImage")) describe_image("new image", *image);
  return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL trace_CreateImageView(VkDevice device, const VkImageViewCreateInfo *info,
                                                            const VkAllocationCallbacks *alloc, VkImageView *view);

static VKAPI_ATTR VkResult VKAPI_CALL trace_CreateBufferView(VkDevice device, const VkBufferViewCreateInfo *info,
                                                             const VkAllocationCallbacks *alloc, VkBufferView *view) {
  VkResult result = find_device(device)->create_buffer_view(device, info, alloc, view);
  if (newly_removed("vkCreateBufferView"))
    fprintf(stderr, "ika trace:   format %d offset %llu range %llu\n", info->format,
            (unsigned long long)info->offset, (unsigned long long)info->range);
  return result;
}

static VKAPI_ATTR void VKAPI_CALL trace_UpdateDescriptorSets(VkDevice device, uint32_t write_count,
                                                             const VkWriteDescriptorSet *writes, uint32_t copy_count,
                                                             const VkCopyDescriptorSet *copies) {
  find_device(device)->update_descriptor_sets(device, write_count, writes, copy_count, copies);
  if (newly_removed("vkUpdateDescriptorSets")) {
    for (uint32_t i = 0; i < write_count; i++) {
      fprintf(stderr, "ika trace:   write %u: type %d binding %u element %u count %u\n", i,
              writes[i].descriptorType, writes[i].dstBinding, writes[i].dstArrayElement,
              writes[i].descriptorCount);
      if (writes[i].pImageInfo &&
          (writes[i].descriptorType == VK_DESCRIPTOR_TYPE_STORAGE_IMAGE ||
           writes[i].descriptorType == VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE ||
           writes[i].descriptorType == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER))
        for (uint32_t j = 0; j < writes[i].descriptorCount && j < 2; j++)
          describe_view("view", writes[i].pImageInfo[j].imageView);
    }
    fprintf(stderr, "ika trace:   %u copies\n", copy_count);
  }
}

static VKAPI_ATTR VkResult VKAPI_CALL trace_AllocateMemory(VkDevice device, const VkMemoryAllocateInfo *info,
                                                           const VkAllocationCallbacks *alloc, VkDeviceMemory *mem) {
  VkResult result = layer_AllocateMemory(device, info, alloc, mem);
  if (newly_removed("vkAllocateMemory"))
    fprintf(stderr, "ika trace:   size %llu type %u result %d\n", (unsigned long long)info->allocationSize,
            info->memoryTypeIndex, result);
  return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL trace_BindImageMemory(VkDevice device, VkImage image, VkDeviceMemory mem,
                                                            VkDeviceSize offset) {
  VkResult result = find_device(device)->bind_image_memory(device, image, mem, offset);
  if (newly_removed("vkBindImageMemory")) describe_image("image", image);
  return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL trace_CreateComputePipelines(VkDevice device, VkPipelineCache cache,
                                                                   uint32_t count,
                                                                   const VkComputePipelineCreateInfo *infos,
                                                                   const VkAllocationCallbacks *alloc,
                                                                   VkPipeline *pipelines) {
  VkResult result = find_device(device)->create_compute_pipelines(device, cache, count, infos, alloc, pipelines);
  newly_removed("vkCreateComputePipelines");
  return result;
}

static VKAPI_ATTR void VKAPI_CALL trace_CmdDispatch(VkCommandBuffer cmd, uint32_t x, uint32_t y, uint32_t z) {
  find_device(cmd)->cmd_dispatch(cmd, x, y, z);
  if (newly_removed("vkCmdDispatch")) fprintf(stderr, "ika trace:   groups %ux%ux%u\n", x, y, z);
}

static VKAPI_ATTR void VKAPI_CALL trace_CmdCopyBufferToImage(VkCommandBuffer cmd, VkBuffer buffer, VkImage image,
                                                             VkImageLayout layout, uint32_t count,
                                                             const VkBufferImageCopy *regions) {
  find_device(cmd)->cmd_copy_buffer_to_image(cmd, buffer, image, layout, count, regions);
  if (newly_removed("vkCmdCopyBufferToImage")) {
    describe_image("dst", image);
    for (uint32_t i = 0; i < count && i < 4; i++)
      fprintf(stderr, "ika trace:   region %u: mip %u layers %u+%u extent %ux%u rowLength %u\n", i,
              regions[i].imageSubresource.mipLevel, regions[i].imageSubresource.baseArrayLayer,
              regions[i].imageSubresource.layerCount, regions[i].imageExtent.width,
              regions[i].imageExtent.height, regions[i].bufferRowLength);
  }
}

static VKAPI_ATTR void VKAPI_CALL trace_CmdPipelineBarrier(VkCommandBuffer cmd, VkPipelineStageFlags src,
                                                           VkPipelineStageFlags dst, VkDependencyFlags deps,
                                                           uint32_t mem_count, const VkMemoryBarrier *mem,
                                                           uint32_t buf_count, const VkBufferMemoryBarrier *bufs,
                                                           uint32_t img_count, const VkImageMemoryBarrier *imgs) {
  find_device(cmd)->cmd_pipeline_barrier(cmd, src, dst, deps, mem_count, mem, buf_count, bufs, img_count, imgs);
  if (newly_removed("vkCmdPipelineBarrier")) {
    for (uint32_t i = 0; i < img_count && i < 4; i++) {
      fprintf(stderr, "ika trace:   barrier %u: layout %d -> %d mips %u+%u\n", i, imgs[i].oldLayout,
              imgs[i].newLayout, imgs[i].subresourceRange.baseMipLevel, imgs[i].subresourceRange.levelCount);
      describe_image("image", imgs[i].image);
    }
  }
}

static VKAPI_ATTR VkResult VKAPI_CALL trace_QueueSubmit(VkQueue queue, uint32_t count, const VkSubmitInfo *submits,
                                                        VkFence fence) {
  VkResult result = find_device(queue)->queue_submit(queue, count, submits, fence);
  if (newly_removed("vkQueueSubmit")) fprintf(stderr, "ika trace:   result %d\n", result);
  return result;
}

/* Images gfxstream decompresses into (MUTABLE_FORMAT | EXTENDED_USAGE), whose
 * memory it shares with its own block images. Open addressing; 0 is empty,
 * 1 is a deleted slot. */
#define ALIAS_TABLE_SIZE 4096u
static uint64_t alias_images[ALIAS_TABLE_SIZE];
static pthread_mutex_t alias_lock = PTHREAD_MUTEX_INITIALIZER;

static void alias_add(VkImage image) {
  uint64_t h = (uint64_t)image;
  pthread_mutex_lock(&alias_lock);
  for (uint32_t i = 0; i < ALIAS_TABLE_SIZE; i++) {
    uint64_t *slot = &alias_images[(h / 8 + i) % ALIAS_TABLE_SIZE];
    if (*slot <= 1 || *slot == h) {
      *slot = h;
      break;
    }
  }
  pthread_mutex_unlock(&alias_lock);
}

static uint64_t *alias_find_locked(VkImage image) {
  uint64_t h = (uint64_t)image;
  for (uint32_t i = 0; i < ALIAS_TABLE_SIZE; i++) {
    uint64_t *slot = &alias_images[(h / 8 + i) % ALIAS_TABLE_SIZE];
    if (*slot == h) return slot;
    if (!*slot) return NULL;
  }
  return NULL;
}

static int alias_contains(VkImage image) {
  pthread_mutex_lock(&alias_lock);
  int found = alias_find_locked(image) != NULL;
  pthread_mutex_unlock(&alias_lock);
  return found;
}

static void alias_remove(VkImage image) {
  pthread_mutex_lock(&alias_lock);
  uint64_t *slot = alias_find_locked(image);
  if (slot) *slot = 1;
  pthread_mutex_unlock(&alias_lock);
}

static VKAPI_ATTR void VKAPI_CALL layer_DestroyImage(VkDevice device, VkImage image,
                                                     const VkAllocationCallbacks *alloc) {
  if (image) alias_remove(image);
  find_device(device)->destroy_image_next(device, image, alloc);
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_AllocateMemory(VkDevice device, const VkMemoryAllocateInfo *info,
                                                           const VkAllocationCallbacks *alloc,
                                                           VkDeviceMemory *memory) {
  struct device_data *data = find_device(device);
  const VkMemoryDedicatedAllocateInfo *dedicated = NULL;
  int external = 0;
  for (const VkBaseInStructure *s = info->pNext; s; s = s->pNext) {
    switch (s->sType) {
    case VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO:
      dedicated = (const VkMemoryDedicatedAllocateInfo *)s;
      break;
    case VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO:
    case VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR:
    case VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT:
    case VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID:
      external = 1;
      break;
    default:
      break;
    }
  }
  if (!dedicated || external || !dedicated->image || !alias_contains(dedicated->image))
    return data->allocate_memory_next(device, info, alloc, memory);

  VkMemoryAllocateInfo fixed = *info;
  struct unlinked removed[MAX_UNLINKED];
  int n = unlink_structs(&fixed, VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, removed);
  VkResult result = data->allocate_memory_next(device, &fixed, alloc, memory);
  restore_chain(removed, n);
  return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateImage(VkDevice device, const VkImageCreateInfo *info,
                                                        const VkAllocationCallbacks *alloc, VkImage *image) {
  const VkImageCreateFlags emulated_output = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT | VK_IMAGE_CREATE_EXTENDED_USAGE_BIT;
  if ((info->flags & emulated_output) == emulated_output) {
    VkResult result = layer_CreateImageInner(device, info, alloc, image);
    if (result == VK_SUCCESS) alias_add(*image);
    return result;
  }
  return layer_CreateImageInner(device, info, alloc, image);
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateImageInner(VkDevice device, const VkImageCreateInfo *info,
                                                             const VkAllocationCallbacks *alloc, VkImage *image) {
  struct device_data *data = find_device(device);
  if (!(info->flags & VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT))
    return data->create_image_next(device, info, alloc, image);

  VkImageCreateInfo fixed = *info;
  struct unlinked removed[MAX_UNLINKED];
  int n = unlink_structs(&fixed, VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO, removed);
  if (n && tracing()) {
    const VkImageFormatListCreateInfo *list = (const VkImageFormatListCreateInfo *)removed[0].removed;
    char formats[128] = "";
    int len = 0;
    for (uint32_t i = 0; i < list->viewFormatCount && len < (int)sizeof(formats) - 8; i++)
      len += snprintf(formats + len, sizeof(formats) - len, " %d", list->pViewFormats[i]);
    fprintf(stderr, "ika trace: dropped format list [%s ] of mutable image format %d %ux%u\n", formats,
            info->format, info->extent.width, info->extent.height);
  }
  VkResult result = data->create_image_next(device, &fixed, alloc, image);
  restore_chain(removed, n);
  return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateSamplerYcbcrConversion(VkDevice device,
                                                                         const VkSamplerYcbcrConversionCreateInfo *info,
                                                                         const VkAllocationCallbacks *alloc,
                                                                         VkSamplerYcbcrConversion *conversion) {
  (void)device;
  (void)info;
  (void)alloc;
  void *placeholder = malloc(1);
  if (!placeholder) return VK_ERROR_OUT_OF_HOST_MEMORY;
  *conversion = (VkSamplerYcbcrConversion)(uintptr_t)placeholder;
  return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL layer_DestroySamplerYcbcrConversion(VkDevice device,
                                                                     VkSamplerYcbcrConversion conversion,
                                                                     const VkAllocationCallbacks *alloc) {
  (void)device;
  (void)alloc;
  free((void *)(uintptr_t)conversion);
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateSampler(VkDevice device, const VkSamplerCreateInfo *info,
                                                          const VkAllocationCallbacks *alloc, VkSampler *sampler) {
  struct device_data *data = find_device(device);
  VkSamplerCreateInfo fixed = *info;
  struct unlinked removed[MAX_UNLINKED];
  int n = unlink_structs(&fixed, VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO, removed);
  VkResult result = data->create_sampler(device, &fixed, alloc, sampler);
  restore_chain(removed, n);
  if (tracing() && newly_removed("vkCreateSampler"))
    fprintf(stderr, "ika trace:   filters %d/%d mipmap %d address %d/%d/%d aniso %d compare %d border %d\n",
            info->magFilter, info->minFilter, info->mipmapMode, info->addressModeU, info->addressModeV,
            info->addressModeW, info->anisotropyEnable, info->compareEnable, info->borderColor);
  return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateImageView(VkDevice device, const VkImageViewCreateInfo *info,
                                                            const VkAllocationCallbacks *alloc, VkImageView *view) {
  struct device_data *data = find_device(device);
  VkImageViewCreateInfo fixed = *info;
  struct unlinked removed[MAX_UNLINKED];
  int n = unlink_structs(&fixed, VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO, removed);
  VkResult result = data->create_image_view(device, &fixed, alloc, view);
  restore_chain(removed, n);
  if (tracing() && result == VK_SUCCESS) remember_view(*view, info);
  if (tracing() && newly_removed("vkCreateImageView")) {
    VkImageUsageFlags usage = 0;
    for (const VkBaseInStructure *s = info->pNext; s; s = s->pNext)
      if (s->sType == VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO)
        usage = ((const VkImageViewUsageCreateInfo *)s)->usage;
    fprintf(stderr, "ika trace:   view type %d format %d aspect %#x mips %u+%u layers %u+%u usage %#x result %d\n",
            info->viewType, info->format, info->subresourceRange.aspectMask, info->subresourceRange.baseMipLevel,
            info->subresourceRange.levelCount, info->subresourceRange.baseArrayLayer,
            info->subresourceRange.layerCount, usage, result);
    describe_image("image", info->image);
  }
  return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL trace_CreateImageView(VkDevice device, const VkImageViewCreateInfo *info,
                                                            const VkAllocationCallbacks *alloc, VkImageView *view) {
  return layer_CreateImageView(device, info, alloc, view);
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL ika_dzn_fix_GetDeviceProcAddr(VkDevice device, const char *name) {
  if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)ika_dzn_fix_GetDeviceProcAddr;
  if (!strcmp(name, "vkDestroyDevice")) return (PFN_vkVoidFunction)layer_DestroyDevice;
  struct device_data *data = find_device(device);
  if (!data) return NULL;
  if (tracing()) {
    static const struct {
      const char *name;
      PFN_vkVoidFunction fn;
    } traced[] = {
        {"vkCreateImage", (PFN_vkVoidFunction)trace_CreateImage},
        {"vkCreateImageView", (PFN_vkVoidFunction)trace_CreateImageView},
        {"vkCreateSampler", (PFN_vkVoidFunction)layer_CreateSampler},
        {"vkCreateBufferView", (PFN_vkVoidFunction)trace_CreateBufferView},
        {"vkUpdateDescriptorSets", (PFN_vkVoidFunction)trace_UpdateDescriptorSets},
        {"vkAllocateMemory", (PFN_vkVoidFunction)trace_AllocateMemory},
        {"vkBindImageMemory", (PFN_vkVoidFunction)trace_BindImageMemory},
        {"vkCreateComputePipelines", (PFN_vkVoidFunction)trace_CreateComputePipelines},
        {"vkCmdDispatch", (PFN_vkVoidFunction)trace_CmdDispatch},
        {"vkCmdCopyBufferToImage", (PFN_vkVoidFunction)trace_CmdCopyBufferToImage},
        {"vkCmdPipelineBarrier", (PFN_vkVoidFunction)trace_CmdPipelineBarrier},
        {"vkQueueSubmit", (PFN_vkVoidFunction)trace_QueueSubmit},
    };
    for (size_t i = 0; i < sizeof(traced) / sizeof(traced[0]); i++)
      if (!strcmp(name, traced[i].name)) return traced[i].fn;
  }
  if (!strcmp(name, "vkCreateImage")) return (PFN_vkVoidFunction)layer_CreateImage;
  if (!strcmp(name, "vkDestroyImage")) return (PFN_vkVoidFunction)layer_DestroyImage;
  if (!strcmp(name, "vkAllocateMemory")) return (PFN_vkVoidFunction)layer_AllocateMemory;
  if (data->fake_ycbcr) {
    if (!strcmp(name, "vkCreateSamplerYcbcrConversion") || !strcmp(name, "vkCreateSamplerYcbcrConversionKHR"))
      return (PFN_vkVoidFunction)layer_CreateSamplerYcbcrConversion;
    if (!strcmp(name, "vkDestroySamplerYcbcrConversion") || !strcmp(name, "vkDestroySamplerYcbcrConversionKHR"))
      return (PFN_vkVoidFunction)layer_DestroySamplerYcbcrConversion;
    if (!strcmp(name, "vkCreateSampler")) return (PFN_vkVoidFunction)layer_CreateSampler;
    if (!strcmp(name, "vkCreateImageView")) return (PFN_vkVoidFunction)layer_CreateImageView;
  }
  return data->gdpa(device, name);
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL ika_dzn_fix_GetInstanceProcAddr(VkInstance instance,
                                                                                const char *name) {
  if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)ika_dzn_fix_GetInstanceProcAddr;
  if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)ika_dzn_fix_GetDeviceProcAddr;
  if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)layer_CreateInstance;
  if (!strcmp(name, "vkDestroyInstance")) return (PFN_vkVoidFunction)layer_DestroyInstance;
  if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunction)layer_CreateDevice;
  if (!strcmp(name, "vkDestroyDevice")) return (PFN_vkVoidFunction)layer_DestroyDevice;
  if (!strcmp(name, "vkGetPhysicalDeviceImageFormatProperties2"))
    return (PFN_vkVoidFunction)layer_GetPhysicalDeviceImageFormatProperties2;
  if (!strcmp(name, "vkGetPhysicalDeviceImageFormatProperties2KHR"))
    return (PFN_vkVoidFunction)layer_GetPhysicalDeviceImageFormatProperties2KHR;
  if (!strcmp(name, "vkEnumerateDeviceExtensionProperties"))
    return (PFN_vkVoidFunction)layer_EnumerateDeviceExtensionProperties;
  if (!strcmp(name, "vkGetPhysicalDeviceFeatures2")) return (PFN_vkVoidFunction)layer_GetPhysicalDeviceFeatures2;
  if (!strcmp(name, "vkGetPhysicalDeviceFeatures2KHR"))
    return (PFN_vkVoidFunction)layer_GetPhysicalDeviceFeatures2KHR;
  if (!strcmp(name, "vkGetPhysicalDeviceProperties2"))
    return (PFN_vkVoidFunction)layer_GetPhysicalDeviceProperties2;
  if (!strcmp(name, "vkGetPhysicalDeviceProperties2KHR"))
    return (PFN_vkVoidFunction)layer_GetPhysicalDeviceProperties2KHR;
  if (!instance) return NULL;
  struct instance_data *data = find_instance(instance);
  return data ? data->gipa(instance, name) : NULL;
}
