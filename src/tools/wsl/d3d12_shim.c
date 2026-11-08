/*
 * libd3d12.so shim for Ika on WSL2: hands Mesa Dozen D3D12 devices from a
 * process-wide pool.
 *
 * Dozen creates an ID3D12DeviceFactory per VkInstance, and each factory creates
 * its own ID3D12Device. WSL's D3D12 runtime does not give back all of a released
 * device's GPU virtual address space (dmesg: "dxgkio_reserve_gpu_va: Ioctl
 * failed: -75"), so a long-lived process that keeps creating instances, as
 * gfxstream does for every Android app, runs out after about 100 of them:
 * ID3D12DeviceFactory::CreateDevice fails and Vulkan reports no GPU. WSL also
 * allows only about ten live devices per process.
 *
 * One device for every instance avoided that, but a device keeps the cost of
 * everything that ever ran on it: after 3DMark Wild Life Extreme had shared it
 * with Geekbench's GPU benchmark, which creates thousands of D3D12 resources,
 * the NVIDIA driver spent half the render threads' time walking a list it keeps
 * per device, and 3DMark ran 30% slower until Ika restarted (RTX 4080 Laptop
 * GPU). So the shim hands out one process-wide device factory, wrapped so that
 * it keeps a reference to every device it creates, and gives each CreateDevice:
 *
 *  - a pooled device no instance is using any more, if one has created fewer
 *    than IKA_D3D12_DEVICE_CHURN (4096) resources and heaps;
 *  - else a new device, while fewer than IKA_D3D12_DEVICES (8) are alive;
 *  - else the live device that has created the fewest, shared.
 *
 * A device no instance uses that has gone over the churn limit is released.
 * Devices are only created for instances running at the same time and after a
 * heavy app, so far fewer than the ~100 WSL allows. IKA_D3D12_SHIM_DEBUG=1 logs
 * each decision. All other exports are forwarded to the real library.
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

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
#define MAX_POOLED 12
static struct pooled_device {
  uint64_t luid;
  void *device;
  /* Resources, heaps and descriptor heaps created on this device. */
  volatile uint64_t churn;
} pool[MAX_POOLED];
static int pool_count;
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

/* D3D12_DEVICE_FACTORY_FLAG_ALLOW_RETURNING_EXISTING_DEVICE and
 * ..._INCOMPATIBLE_EXISTING_DEVICE, which Dozen sets: they would hand the
 * factory's existing device back for every CreateDevice. The pool decides. */
static uintptr_t w_set_flags(void *self, uintptr_t flags, uintptr_t b, uintptr_t c, uintptr_t d, uintptr_t e) {
  (void)self;
  return ((uintptr_t (*)(void *, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t))real_method(
      SLOT_SET_FLAGS))(wrapper.real, flags & ~(uintptr_t)0x3, b, c, d, e);
}
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

/* ---- Churn: count what each pooled device creates ---- */

/* ID3D12Device vtable slots counted, and the next functions. */
enum { SLOT_CREATE_DESCRIPTOR_HEAP = 14, SLOT_CREATE_COMMITTED = 27, SLOT_CREATE_HEAP = 28, SLOT_CREATE_PLACED = 29,
       SLOT_CREATE_COMMITTED1 = 53, CHURN_SLOTS = 54 };
static void *churn_next[CHURN_SLOTS];

static void count_churn(void *device) {
  for (int i = 0; i < pool_count; i++)
    if (pool[i].device == device) {
      __atomic_add_fetch(&pool[i].churn, 1, __ATOMIC_RELAXED);
      return;
    }
}

static int32_t churn_descriptor_heap(void *self, const void *desc, const guid *iid, void **out) {
  count_churn(self);
  return ((int32_t (*)(void *, const void *, const guid *, void **))churn_next[SLOT_CREATE_DESCRIPTOR_HEAP])(self, desc, iid, out);
}
static int32_t churn_committed(void *self, const void *props, int32_t flags, const void *desc, int32_t state,
                               const void *clear, const guid *iid, void **out) {
  count_churn(self);
  return ((int32_t (*)(void *, const void *, int32_t, const void *, int32_t, const void *, const guid *, void **))
              churn_next[SLOT_CREATE_COMMITTED])(self, props, flags, desc, state, clear, iid, out);
}
static int32_t churn_heap(void *self, const void *desc, const guid *iid, void **out) {
  count_churn(self);
  return ((int32_t (*)(void *, const void *, const guid *, void **))churn_next[SLOT_CREATE_HEAP])(self, desc, iid, out);
}
static int32_t churn_placed(void *self, void *heap, uint64_t offset, const void *desc, int32_t state, const void *clear,
                            const guid *iid, void **out) {
  count_churn(self);
  return ((int32_t (*)(void *, void *, uint64_t, const void *, int32_t, const void *, const guid *, void **))
              churn_next[SLOT_CREATE_PLACED])(self, heap, offset, desc, state, clear, iid, out);
}
static int32_t churn_committed1(void *self, const void *props, int32_t flags, const void *desc, int32_t state,
                                const void *clear, void *session, const guid *iid, void **out) {
  count_churn(self);
  return ((int32_t (*)(void *, const void *, int32_t, const void *, int32_t, const void *, void *, const guid *,
                       void **))churn_next[SLOT_CREATE_COMMITTED1])(self, props, flags, desc, state, clear, session, iid, out);
}

/* Every device of a class shares one vtable: wrap its creation methods once. */
static void hook_churn(void *device) {
  void **vtable = *(void ***)device;
  if (churn_next[SLOT_CREATE_HEAP]) return;
  long page = sysconf(_SC_PAGESIZE);
  uintptr_t start = (uintptr_t)vtable & ~(uintptr_t)(page - 1);
  uintptr_t end = ((uintptr_t)(vtable + CHURN_SLOTS) + page - 1) & ~(uintptr_t)(page - 1);
  if (mprotect((void *)start, end - start, PROT_READ | PROT_WRITE)) return;
  static const struct { int slot; void *hook; } hooks[] = {
      {SLOT_CREATE_DESCRIPTOR_HEAP, (void *)churn_descriptor_heap}, {SLOT_CREATE_COMMITTED, (void *)churn_committed},
      {SLOT_CREATE_HEAP, (void *)churn_heap}, {SLOT_CREATE_PLACED, (void *)churn_placed},
      {SLOT_CREATE_COMMITTED1, (void *)churn_committed1}};
  for (unsigned i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
    churn_next[hooks[i].slot] = vtable[hooks[i].slot];
    vtable[hooks[i].slot] = hooks[i].hook;
  }
}

/* ---- The pool ---- */

static uint64_t env_number(const char *name, uint64_t fallback) {
  const char *v = getenv(name);
  return v && *v ? strtoull(v, NULL, 10) : fallback;
}

/* The device's references besides the pool's own. */
static uint32_t other_refs(void *device) {
  ((add_ref_fn)(*(void ***)device)[SLOT_ADD_REF])(device);
  uint32_t left = ((uint32_t (*)(void *))(*(void ***)device)[SLOT_RELEASE])(device);
  return left - 1;
}

/* Releases the pooled devices no instance uses that are over the churn limit.
 * Not with IKA_D3D12_DRED=1, whose threads keep polling every device. */
static void release_spent(uint64_t churn_limit, int debug) {
  const char *dred = getenv("IKA_D3D12_DRED");
  if (dred && dred[0] == '1') return;
  for (int i = 0; i < pool_count;) {
    if (pool[i].churn >= churn_limit && other_refs(pool[i].device) == 0) {
      if (debug) fprintf(stderr, "ika d3d12 shim: released device %p after %llu creations\n", pool[i].device,
                         (unsigned long long)pool[i].churn);
      ((uint32_t (*)(void *))(*(void ***)pool[i].device)[SLOT_RELEASE])(pool[i].device);
      pool[i] = pool[--pool_count];
      continue;
    }
    i++;
  }
}

static int32_t w_create_device(void *self, void *adapter, int32_t feature_level, const guid *iid, void **out) {
  typedef int32_t (*create_device_fn)(void *, void *, int32_t, const guid *, void **);
  typedef int32_t (*query_interface_fn)(void *, const guid *, void **);
  (void)self;
  uint64_t luid;
  if (!out || !iid || !adapter_luid(adapter, &luid))
    return ((create_device_fn)real_method(SLOT_CREATE_DEVICE))(wrapper.real, adapter, feature_level, iid, out);

  const uint64_t churn_limit = env_number("IKA_D3D12_DEVICE_CHURN", 4096);
  uint64_t max_devices = env_number("IKA_D3D12_DEVICES", 8);
  if (max_devices < 1) max_devices = 1;
  if (max_devices > MAX_POOLED) max_devices = MAX_POOLED;
  const int debug = getenv("IKA_D3D12_SHIM_DEBUG") != NULL;

  pthread_mutex_lock(&factory_lock);
  release_spent(churn_limit, debug);

  int32_t hr;
  const char *how;
  void *device = NULL;
  /* A device no instance uses any more, under the churn limit. */
  for (int i = 0; i < pool_count && !device; i++)
    if (pool[i].luid == luid && pool[i].churn < churn_limit && other_refs(pool[i].device) == 0) device = pool[i].device;
  how = "reused";
  int live = 0;
  for (int i = 0; i < pool_count; i++) live += pool[i].luid == luid;
  if (!device && (uint64_t)live < max_devices && pool_count < MAX_POOLED) {
    hr = ((create_device_fn)real_method(SLOT_CREATE_DEVICE))(wrapper.real, adapter, feature_level, iid, out);
    if (hr >= 0 && *out) {
      ((add_ref_fn)(*(void ***)*out)[SLOT_ADD_REF])(*out);
      pool[pool_count].luid = luid;
      pool[pool_count].device = *out;
      pool[pool_count].churn = 0;
      pool_count++;
      hook_churn(*out);
      ika_dred_watch(*out);
      ika_dred_hook_device(*out);
    }
    if (debug)
      fprintf(stderr, "ika d3d12 shim: CreateDevice(luid=%#llx) = %#x -> %p (new, %d of %llu)\n",
              (unsigned long long)luid, (unsigned)hr, *out, live + 1, (unsigned long long)max_devices);
    pthread_mutex_unlock(&factory_lock);
    return hr;
  }
  if (!device) {
    /* At the limit: share the live device that has created the fewest. */
    uint64_t least = UINT64_MAX;
    for (int i = 0; i < pool_count; i++)
      if (pool[i].luid == luid && pool[i].churn < least) {
        least = pool[i].churn;
        device = pool[i].device;
      }
    how = "shared";
  }
  if (device) {
    hr = ((query_interface_fn)(*(void ***)device)[SLOT_QUERY_INTERFACE])(device, iid, out);
  } else {
    hr = ((create_device_fn)real_method(SLOT_CREATE_DEVICE))(wrapper.real, adapter, feature_level, iid, out);
    how = "unpooled";
  }
  if (debug)
    fprintf(stderr, "ika d3d12 shim: CreateDevice(luid=%#llx) = %#x -> %p (%s)\n", (unsigned long long)luid,
            (unsigned)hr, *out, how);
  pthread_mutex_unlock(&factory_lock);
  return hr;
}

static void reset_in_child(void) {
  pthread_mutex_init(&factory_lock, NULL);
  shared_factory = NULL;
  wrapper.real = NULL;
  pool_count = 0;
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
