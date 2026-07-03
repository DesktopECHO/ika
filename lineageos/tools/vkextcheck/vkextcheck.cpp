// vkextcheck — minimal native Vulkan extension enumerator.
//
// Runs as an x86_64 binary (no arm64/Berberis translation) so it exercises the
// real gfxstream guest driver (vulkan.ranchu.so) directly. Prints instance and
// per-device extension lists and flags the gfxstream extensions advertised by
// the "Expose backed gfxstream Vulkan extensions" mesa patch.

#include <vulkan/vulkan.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

// Extensions newly advertised by lineageos/patches/external-mesa3d.patch.
const char* kWatchedDeviceExtensions[] = {
    "VK_KHR_maintenance5",
    "VK_EXT_host_image_copy",
    "VK_KHR_16bit_storage",
    "VK_KHR_vertex_attribute_divisor",
    "VK_EXT_external_memory_acquire_unmodified",
};

const char* ResultName(VkResult r) {
  switch (r) {
    case VK_SUCCESS: return "VK_SUCCESS";
    case VK_INCOMPLETE: return "VK_INCOMPLETE";
    case VK_ERROR_OUT_OF_HOST_MEMORY: return "VK_ERROR_OUT_OF_HOST_MEMORY";
    case VK_ERROR_OUT_OF_DEVICE_MEMORY: return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
    case VK_ERROR_INITIALIZATION_FAILED: return "VK_ERROR_INITIALIZATION_FAILED";
    case VK_ERROR_LAYER_NOT_PRESENT: return "VK_ERROR_LAYER_NOT_PRESENT";
    case VK_ERROR_EXTENSION_NOT_PRESENT: return "VK_ERROR_EXTENSION_NOT_PRESENT";
    case VK_ERROR_INCOMPATIBLE_DRIVER: return "VK_ERROR_INCOMPATIBLE_DRIVER";
    default: return "VK_ERROR_<other>";
  }
}

std::vector<VkExtensionProperties> DeviceExtensions(VkPhysicalDevice dev) {
  uint32_t count = 0;
  vkEnumerateDeviceExtensionProperties(dev, nullptr, &count, nullptr);
  std::vector<VkExtensionProperties> exts(count);
  if (count) vkEnumerateDeviceExtensionProperties(dev, nullptr, &count, exts.data());
  return exts;
}

bool HasExt(const std::vector<VkExtensionProperties>& exts, const char* name) {
  for (const auto& e : exts)
    if (std::strcmp(e.extensionName, name) == 0) return true;
  return false;
}

}  // namespace

int main() {
  uint32_t instExtCount = 0;
  vkEnumerateInstanceExtensionProperties(nullptr, &instExtCount, nullptr);
  std::vector<VkExtensionProperties> instExts(instExtCount);
  if (instExtCount)
    vkEnumerateInstanceExtensionProperties(nullptr, &instExtCount, instExts.data());
  printf("Instance extensions (%u):\n", instExtCount);
  for (const auto& e : instExts) printf("  %s (rev %u)\n", e.extensionName, e.specVersion);

  VkApplicationInfo app{};
  app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
  app.pApplicationName = "vkextcheck";
  app.apiVersion = VK_API_VERSION_1_3;

  VkInstanceCreateInfo ici{};
  ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  ici.pApplicationInfo = &app;

  VkInstance instance = VK_NULL_HANDLE;
  VkResult r = vkCreateInstance(&ici, nullptr, &instance);
  if (r != VK_SUCCESS) {
    printf("\nvkCreateInstance failed: %s\n", ResultName(r));
    return 1;
  }

  uint32_t devCount = 0;
  vkEnumeratePhysicalDevices(instance, &devCount, nullptr);
  std::vector<VkPhysicalDevice> devs(devCount);
  if (devCount) vkEnumeratePhysicalDevices(instance, &devCount, devs.data());
  printf("\nPhysical devices: %u\n", devCount);

  for (uint32_t i = 0; i < devCount; ++i) {
    VkPhysicalDeviceProperties p{};
    vkGetPhysicalDeviceProperties(devs[i], &p);
    printf("\n=== Device %u: %s ===\n", i, p.deviceName);
    printf("  apiVersion    %u.%u.%u\n", VK_VERSION_MAJOR(p.apiVersion),
           VK_VERSION_MINOR(p.apiVersion), VK_VERSION_PATCH(p.apiVersion));
    printf("  driverVersion 0x%x   vendorID 0x%x   deviceID 0x%x\n",
           p.driverVersion, p.vendorID, p.deviceID);

    auto exts = DeviceExtensions(devs[i]);
    printf("  device extensions (%zu):\n", exts.size());
    for (const auto& e : exts) printf("    %s (rev %u)\n", e.extensionName, e.specVersion);

    printf("  -- gfxstream patch extensions --\n");
    for (const char* name : kWatchedDeviceExtensions)
      printf("    [%s] %s\n", HasExt(exts, name) ? "PRESENT" : "missing", name);
  }

  vkDestroyInstance(instance, nullptr);
  return 0;
}
