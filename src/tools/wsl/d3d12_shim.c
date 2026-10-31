/*
 * libd3d12.so shim for Ika on WSL2: makes Mesa Dozen share one D3D12 device.
 *
 * Dozen creates an ID3D12DeviceFactory per VkInstance, and each factory creates
 * its own ID3D12Device. WSL's D3D12 runtime does not give back all of a released
 * device's GPU virtual address space (dmesg: "dxgkio_reserve_gpu_va: Ioctl
 * failed: -75"), so a long-lived process that keeps creating instances, as
 * gfxstream does for every Android app, runs out after about 100 of them:
 * ID3D12DeviceFactory::CreateDevice fails and Vulkan reports no GPU.
 *
 * This shim hands out one process-wide device factory, wrapped so that it keeps
 * a reference to every device it creates. Dozen sets
 * D3D12_DEVICE_FACTORY_FLAG_ALLOW_RETURNING_EXISTING_DEVICE on it, so every
 * instance then gets the same, never-released D3D12 device. All other exports
 * are forwarded to the real library.
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REAL_LIB "/usr/lib/wsl/lib/libd3d12.so"
#define EXPORT __attribute__((visibility("default")))

typedef struct {
  uint32_t a;
  uint16_t b, c;
  uint8_t d[8];
} guid;

static const guid CLSID_D3D12DeviceFactory = {0x114863bf, 0xc386, 0x4aee, {0xb3, 0x9d, 0x8f, 0x0b, 0xbb, 0x06, 0x29, 0x55}};
static const guid IID_ID3D12DeviceFactory = {0x61f307d3, 0xd34e, 0x4e7c, {0x83, 0x74, 0x3b, 0xa4, 0xde, 0x23, 0xcc, 0xcb}};

/* d3d12_dred.cpp */
void ika_dred_enable(void *factory);
void ika_dred_watch(void *device);
void ika_dred_hook_device(void *device);

typedef uintptr_t (*fn6)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t);
typedef int32_t (*get_interface_fn)(const guid *, const guid *, void **);
typedef uint32_t (*add_ref_fn)(void *);

static pthread_once_t once = PTHREAD_ONCE_INIT;
static void *real;
static pthread_mutex_t factory_lock = PTHREAD_MUTEX_INITIALIZER;
static void *shared_factory;

/* D3D12 objects don't survive fork(): a child starts with no shared factory or devices. */
static void reset_in_child(void);

static void open_real(void) {
  pthread_atfork(NULL, NULL, reset_in_child);
  real = dlopen(REAL_LIB, RTLD_NOW | RTLD_LOCAL);
  if (!real) fprintf(stderr, "ika d3d12 shim: %s\n", dlerror());
}

static void *real_sym(const char *name) {
  pthread_once(&once, open_real);
  return real ? dlsym(real, name) : NULL;
}

#define FORWARD(name)                                                                              \
  EXPORT uintptr_t name(uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d, uintptr_t e, uintptr_t f) { \
    static fn6 next;                                                                               \
    if (!next) next = (fn6)real_sym(#name);                                                        \
    return next ? next(a, b, c, d, e, f) : (uintptr_t)(int32_t)0x80004005; /* E_FAIL */            \
  }

FORWARD(D3D12CoreCreateLayeredDevice)
FORWARD(D3D12CoreGetLayeredDeviceSize)
FORWARD(D3D12CoreRegisterLayers)
FORWARD(D3D12CreateDevice)
FORWARD(D3D12CreateRootSignatureDeserializer)
FORWARD(D3D12CreateVersionedRootSignatureDeserializer)
FORWARD(D3D12EnableExperimentalFeatures)
FORWARD(D3D12GetDebugInterface)
FORWARD(D3D12SerializeRootSignature)
FORWARD(D3D12SerializeVersionedRootSignature)

/* ID3D12DeviceFactory vtable slots */
enum {
  SLOT_QUERY_INTERFACE,
  SLOT_ADD_REF,
  SLOT_RELEASE,
  SLOT_INITIALIZE_FROM_GLOBAL_STATE,
  SLOT_APPLY_TO_GLOBAL_STATE,
  SLOT_SET_FLAGS,
  SLOT_GET_FLAGS,
  SLOT_GET_CONFIGURATION_INTERFACE,
  SLOT_ENABLE_EXPERIMENTAL_FEATURES,
  SLOT_CREATE_DEVICE,
  SLOT_COUNT,
};

static const guid IID_IUnknown = {0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

struct wrapped_factory {
  void **vtbl;
  void *real;
};

static struct wrapped_factory wrapper;
static struct {
  uint64_t luid;
  void *device;
} held_devices[8];
static int held_count;
static int experimental_enabled;

/* IDXCoreAdapter::GetProperty(DXCoreAdapterProperty::InstanceLuid, ...), vtable slot 6. */
static int adapter_luid(void *adapter, uint64_t *luid) {
  typedef int32_t (*get_property_fn)(void *, uint32_t, size_t, void *);
  return adapter && ((get_property_fn)(*(void ***)adapter)[6])(adapter, 0, sizeof(*luid), luid) >= 0;
}

static inline void *real_method(int slot) { return (*(void ***)wrapper.real)[slot]; }

static int32_t w_query_interface(void *self, const guid *iid, void **out) {
  if (!memcmp(iid, &IID_IUnknown, sizeof(guid)) || !memcmp(iid, &IID_ID3D12DeviceFactory, sizeof(guid))) {
    *out = self;
    return 0;
  }
  return ((int32_t (*)(void *, const guid *, void **))real_method(SLOT_QUERY_INTERFACE))(wrapper.real, iid, out);
}

/* The wrapper is static and never destroyed; the shim owns the real factory's reference. */
static uint32_t w_add_ref(void *self) { (void)self; return 2; }
static uint32_t w_release(void *self) { (void)self; return 1; }

#define WRAP(slot, name)                                                                     \
  static uintptr_t name(void *self, uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d, uintptr_t e) { \
    (void)self;                                                                              \
    return ((uintptr_t (*)(void *, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t))  \
                real_method(slot))(wrapper.real, a, b, c, d, e);                            \
  }

WRAP(SLOT_INITIALIZE_FROM_GLOBAL_STATE, w_initialize_from_global_state)
WRAP(SLOT_APPLY_TO_GLOBAL_STATE, w_apply_to_global_state)
WRAP(SLOT_SET_FLAGS, w_set_flags)
WRAP(SLOT_GET_FLAGS, w_get_flags)
WRAP(SLOT_GET_CONFIGURATION_INTERFACE, w_get_configuration_interface)

static int32_t w_enable_experimental_features(void *self, uint32_t count, const guid *iids, void *structs,
                                              uint32_t *sizes) {
  (void)self;
  pthread_mutex_lock(&factory_lock);
  /* Dozen asks for the same features on every instance; once the shared device exists they are already on. */
  if (experimental_enabled) {
    pthread_mutex_unlock(&factory_lock);
    return 0;
  }
  int32_t hr = ((int32_t (*)(void *, uint32_t, const guid *, void *, uint32_t *))real_method(
      SLOT_ENABLE_EXPERIMENTAL_FEATURES))(wrapper.real, count, iids, structs, sizes);
  if (hr >= 0) experimental_enabled = 1;
  pthread_mutex_unlock(&factory_lock);
  return hr;
}

/*
 * One D3D12 device per adapter for the whole process: the first CreateDevice for
 * an adapter creates it and the shim keeps a reference; later calls for the same
 * adapter LUID get that device through QueryInterface. WSL allows only about ten
 * live D3D12 devices per process and does not return a released device's GPU
 * address space, so creating one per VkInstance fails either way.
 */
static int32_t w_create_device(void *self, void *adapter, int32_t feature_level, const guid *iid, void **out) {
  typedef int32_t (*create_device_fn)(void *, void *, int32_t, const guid *, void **);
  typedef int32_t (*query_interface_fn)(void *, const guid *, void **);
  (void)self;
  uint64_t luid;
  if (!out || !iid || !adapter_luid(adapter, &luid))
    return ((create_device_fn)real_method(SLOT_CREATE_DEVICE))(wrapper.real, adapter, feature_level, iid, out);

  pthread_mutex_lock(&factory_lock);
  int32_t hr;
  void *device = NULL;
  for (int i = 0; i < held_count; i++) {
    if (held_devices[i].luid == luid) device = held_devices[i].device;
  }
  if (device) {
    hr = ((query_interface_fn)(*(void ***)device)[SLOT_QUERY_INTERFACE])(device, iid, out);
  } else {
    hr = ((create_device_fn)real_method(SLOT_CREATE_DEVICE))(wrapper.real, adapter, feature_level, iid, out);
    if (hr >= 0 && *out && held_count < (int)(sizeof(held_devices) / sizeof(held_devices[0]))) {
      ((add_ref_fn)(*(void ***)*out)[SLOT_ADD_REF])(*out);
      held_devices[held_count].luid = luid;
      held_devices[held_count].device = *out;
      held_count++;
      ika_dred_watch(*out);
      ika_dred_hook_device(*out);
    }
  }
  if (getenv("IKA_D3D12_SHIM_DEBUG"))
    fprintf(stderr, "ika d3d12 shim: CreateDevice(luid=%#llx) = %#x -> %p (%s)\n", (unsigned long long)luid,
            (unsigned)hr, *out, device ? "shared" : "new");
  pthread_mutex_unlock(&factory_lock);
  return hr;
}

static void reset_in_child(void) {
  pthread_mutex_init(&factory_lock, NULL);
  shared_factory = NULL;
  wrapper.real = NULL;
  held_count = 0;
  experimental_enabled = 0;
}

static void *wrapper_vtbl[SLOT_COUNT] = {
    [SLOT_QUERY_INTERFACE] = (void *)w_query_interface,
    [SLOT_ADD_REF] = (void *)w_add_ref,
    [SLOT_RELEASE] = (void *)w_release,
    [SLOT_INITIALIZE_FROM_GLOBAL_STATE] = (void *)w_initialize_from_global_state,
    [SLOT_APPLY_TO_GLOBAL_STATE] = (void *)w_apply_to_global_state,
    [SLOT_SET_FLAGS] = (void *)w_set_flags,
    [SLOT_GET_FLAGS] = (void *)w_get_flags,
    [SLOT_GET_CONFIGURATION_INTERFACE] = (void *)w_get_configuration_interface,
    [SLOT_ENABLE_EXPERIMENTAL_FEATURES] = (void *)w_enable_experimental_features,
    [SLOT_CREATE_DEVICE] = (void *)w_create_device,
};

EXPORT int32_t D3D12GetInterface(const guid *clsid, const guid *iid, void **out) {
  static get_interface_fn next;
  if (!next) next = (get_interface_fn)real_sym("D3D12GetInterface");
  if (!next) return (int32_t)0x80004005;

  if (!clsid || !iid || !out || memcmp(clsid, &CLSID_D3D12DeviceFactory, sizeof(guid)) ||
      memcmp(iid, &IID_ID3D12DeviceFactory, sizeof(guid)) || getenv("IKA_D3D12_SHIM_DISABLE")) {
    return next(clsid, iid, out);
  }

  pthread_mutex_lock(&factory_lock);
  if (!shared_factory) {
    int32_t hr = next(clsid, iid, &shared_factory);
    if (hr < 0) {
      shared_factory = NULL;
      pthread_mutex_unlock(&factory_lock);
      *out = NULL;
      return hr;
    }
    wrapper.vtbl = wrapper_vtbl;
    wrapper.real = shared_factory;
    ika_dred_enable(shared_factory);
  }
  *out = &wrapper;
  pthread_mutex_unlock(&factory_lock);
  return 0;
}
