// D3D12 Device Removed Extended Data (DRED) for the libd3d12.so shim: with
// IKA_D3D12_DRED=1, turns on auto-breadcrumbs and page-fault tracking before
// the shared device is created, and reports why a device was removed, which
// GPU commands were in flight and the faulting address, to stderr (crosvm's
// log) and /tmp/ika-dred.log.
#define INITGUID
#include <pthread.h>
#include <stdint.h>
#include <signal.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
#include <wsl/winadapter.h>
#include <directx/d3d12.h>
#include <dxguids/dxguids.h>

static void report(const char *fmt, ...) {
  char line[1024];
  va_list args;
  va_start(args, fmt);
  vsnprintf(line, sizeof(line), fmt, args);
  va_end(args);
  fprintf(stderr, "ika dred: %s\n", line);
  if (FILE *f = fopen("/tmp/ika-dred.log", "a")) {
    fprintf(f, "%s\n", line);
    fclose(f);
  }
}

static bool enabled() {
  const char *v = getenv("IKA_D3D12_DRED");
  return v && v[0] == '1';
}

extern "C" void ika_dred_enable(void *factory_ptr) {
  if (!enabled()) return;
  auto *factory = static_cast<ID3D12DeviceFactory *>(factory_ptr);
  ID3D12DeviceRemovedExtendedDataSettings1 *settings1 = nullptr;
  ID3D12DeviceRemovedExtendedDataSettings *settings = nullptr;
  if (SUCCEEDED(factory->GetConfigurationInterface(CLSID_D3D12DeviceRemovedExtendedData,
                                                   IID_PPV_ARGS(&settings1)))) {
    settings1->SetBreadcrumbContextEnablement(D3D12_DRED_ENABLEMENT_FORCED_ON);
    settings = settings1;
  } else if (FAILED(factory->GetConfigurationInterface(CLSID_D3D12DeviceRemovedExtendedData,
                                                       IID_PPV_ARGS(&settings)))) {
    report("DRED settings are not available");
    return;
  }
  settings->SetAutoBreadcrumbsEnablement(D3D12_DRED_ENABLEMENT_FORCED_ON);
  settings->SetPageFaultEnablement(D3D12_DRED_ENABLEMENT_FORCED_ON);
  report("DRED enabled (breadcrumbs, page faults%s)", settings1 ? ", breadcrumb context" : "");
}

static void dump(ID3D12Device *device, HRESULT reason) {
  report("device %p removed: reason %#x", (void *)device, (unsigned)reason);
  ID3D12DeviceRemovedExtendedData *dred = nullptr;
  if (FAILED(device->QueryInterface(IID_PPV_ARGS(&dred)))) {
    report("no ID3D12DeviceRemovedExtendedData");
    return;
  }

  D3D12_DRED_AUTO_BREADCRUMBS_OUTPUT crumbs = {};
  if (SUCCEEDED(dred->GetAutoBreadcrumbsOutput(&crumbs))) {
    int lists = 0;
    for (const D3D12_AUTO_BREADCRUMB_NODE *node = crumbs.pHeadAutoBreadcrumbNode; node; node = node->pNext) {
      lists++;
      UINT32 done = node->pLastBreadcrumbValue ? *node->pLastBreadcrumbValue : 0;
      if (done >= node->BreadcrumbCount) continue;  // finished on the GPU
      char ops[512];
      int len = 0;
      UINT32 from = done > 4 ? done - 4 : 0;
      UINT32 to = done + 4 < node->BreadcrumbCount ? done + 4 : node->BreadcrumbCount;
      for (UINT32 i = from; i < to && len < (int)sizeof(ops) - 16; i++)
        len += snprintf(ops + len, sizeof(ops) - len, "%s%d%s", i == done ? "[" : "",
                        (int)node->pCommandHistory[i], i == done ? "]" : "");
      report("unfinished command list %p queue %p: %u/%u ops done; ops %u..%u (current in []): %s",
             (void *)node->pCommandList, (void *)node->pCommandQueue, done, node->BreadcrumbCount, from,
             to, ops);
    }
    report("%d command lists in breadcrumbs", lists);
  } else {
    report("no breadcrumbs");
  }

  D3D12_DRED_PAGE_FAULT_OUTPUT fault = {};
  if (SUCCEEDED(dred->GetPageFaultAllocationOutput(&fault))) {
    report("page fault VA %#llx", (unsigned long long)fault.PageFaultVA);
    for (const D3D12_DRED_ALLOCATION_NODE *n = fault.pHeadExistingAllocationNode; n; n = n->pNext)
      report("  existing allocation at fault: type %d name %s", (int)n->AllocationType,
             n->ObjectNameA ? n->ObjectNameA : "-");
    for (const D3D12_DRED_ALLOCATION_NODE *n = fault.pHeadRecentFreedAllocationNode; n; n = n->pNext)
      report("  recently freed allocation: type %d name %s", (int)n->AllocationType,
             n->ObjectNameA ? n->ObjectNameA : "-");
  } else {
    report("no page fault output");
  }
  dred->Release();
}

/* Devices being watched, for the crash handler. */
static ID3D12Device *watched[8];
static int watched_count;
static struct sigaction previous_segv;

/* The device removal and a driver's NULL dereference can come microseconds
 * apart on the same thread, before the watcher polls; dump from the crash
 * itself, then let the previous handler (or the default action) run. */
static void on_segv(int sig, siginfo_t *info, void *context) {
  static volatile sig_atomic_t dumping, dumped;
  /* crosvm handles some SIGSEGVs itself; a driver's NULL dereference faults near 0. */
  bool null_deref = info && (uintptr_t)info->si_addr < 0x10000;
  if (!dumping && !dumped) {
    dumping = 1;
    for (int i = 0; i < watched_count; i++) {
      HRESULT reason = watched[i]->GetDeviceRemovedReason();
      if (FAILED(reason) || null_deref) {
        report("SIGSEGV at %p; device %p removed reason %#x", info ? info->si_addr : nullptr,
               (void *)watched[i], (unsigned)reason);
        dump(watched[i], reason);
        dumped = 1;
      }
    }
    dumping = 0;
  }
  if (previous_segv.sa_flags & SA_SIGINFO) {
    if (previous_segv.sa_sigaction) {
      previous_segv.sa_sigaction(sig, info, context);
      return;
    }
  } else if (previous_segv.sa_handler != SIG_DFL && previous_segv.sa_handler != SIG_IGN) {
    previous_segv.sa_handler(sig);
    return;
  }
  signal(sig, SIG_DFL);
  raise(sig);
}

/* crosvm installs its own SIGSEGV handler after the device exists; keep ours
 * first in the chain. */
static void ensure_segv_handler() {
  struct sigaction current;
  if (sigaction(SIGSEGV, nullptr, &current) != 0) return;
  if ((current.sa_flags & SA_SIGINFO) && current.sa_sigaction == on_segv) return;
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_sigaction = on_segv;
  action.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigemptyset(&action.sa_mask);
  sigaction(SIGSEGV, &action, &previous_segv);
}

static void *watch(void *device_ptr) {
  auto *device = static_cast<ID3D12Device *>(device_ptr);
  for (;;) {
    ensure_segv_handler();
    HRESULT reason = device->GetDeviceRemovedReason();
    if (FAILED(reason)) {
      dump(device, reason);
      return nullptr;
    }
    usleep(10000);
  }
}

extern "C" void ika_dred_watch(void *device) {
  if (!enabled()) return;
  if (watched_count < (int)(sizeof(watched) / sizeof(watched[0])))
    watched[watched_count++] = static_cast<ID3D12Device *>(device);
  if (watched_count == 1) ensure_segv_handler();
  pthread_t thread;
  if (pthread_create(&thread, nullptr, watch, device) == 0) pthread_detach(thread);
}

/* For VK_LAYER_IKA_dzn_fix: the first watched device's removed reason (0 if
 * none is removed), so the layer can name the Vulkan call that removed it. */
extern "C" __attribute__((visibility("default"))) int ika_d3d12_removed_reason(void) {
  for (int i = 0; i < watched_count; i++) {
    HRESULT reason = watched[i]->GetDeviceRemovedReason();
    if (FAILED(reason)) return (int)reason;
  }
  return 0;
}

/* ---- D3D12 call tracing (IKA_D3D12_DRED=1) ----
 * Wraps the shared device's descriptor and view creation methods: after each
 * call, if the device has just been removed, log the call, its arguments and
 * a native backtrace. D3D12's Create*View methods return nothing, so invalid
 * arguments only show up as a removed device. */
#include <execinfo.h>
#include <sys/mman.h>

enum {
  SLOT_CREATE_DESCRIPTOR_HEAP = 14,
  SLOT_CREATE_SRV = 18,
  SLOT_CREATE_UAV = 19,
  SLOT_CREATE_RTV = 20,
  SLOT_CREATE_DSV = 21,
  SLOT_CREATE_SAMPLER = 22,
  SLOT_COPY_DESCRIPTORS = 23,
  SLOT_COPY_DESCRIPTORS_SIMPLE = 24,
  SLOT_COUNT_HOOKED = 25,
};

static void *original[SLOT_COUNT_HOOKED];
static volatile int call_reported;

/* ID3D12Resource::GetDesc, slot 10. On Linux the runtime follows the Itanium C++
 * ABI: the returned struct's address comes first, before this. */
static void resource_desc(void *resource, D3D12_RESOURCE_DESC *desc) {
  typedef void (*get_desc_fn)(D3D12_RESOURCE_DESC *, void *);
  memset(desc, 0, sizeof(*desc));
  if (resource) ((get_desc_fn)(*(void ***)resource)[10])(desc, resource);
}

static void log_resource(void *resource) {
  if (!resource) {
    report("  resource: NULL");
    return;
  }
  D3D12_RESOURCE_DESC d;
  resource_desc(resource, &d);
  report("  resource %p: dimension %d format %d %llux%u depth/array %u mips %u samples %u layout %d flags %#x",
         resource, d.Dimension, d.Format, (unsigned long long)d.Width, d.Height, d.DepthOrArraySize, d.MipLevels,
         d.SampleDesc.Count, d.Layout, d.Flags);
}

static int check_removed(void *device, const char *call) {
  if (call_reported) return 0;
  HRESULT reason = static_cast<ID3D12Device *>(device)->GetDeviceRemovedReason();
  if (SUCCEEDED(reason)) return 0;
  call_reported = 1;
  report("D3D12 device removed (reason %#x) by %s", (unsigned)reason, call);
  void *frames[24];
  int n = backtrace(frames, 24);
  char **names = backtrace_symbols(frames, n);
  for (int i = 1; i < n; i++) {
    Dl_info info;
    if (dladdr(frames[i], &info) && info.dli_fname)
      report("  #%d %s+%#lx (%s)", i, info.dli_fname, (unsigned long)((char *)frames[i] - (char *)info.dli_fbase),
             names ? names[i] : "?");
  }
  return 1;
}

static void hook_uav(void *self, void *resource, void *counter, const D3D12_UNORDERED_ACCESS_VIEW_DESC *desc,
                     D3D12_CPU_DESCRIPTOR_HANDLE dest) {
  ((void (*)(void *, void *, void *, const D3D12_UNORDERED_ACCESS_VIEW_DESC *, D3D12_CPU_DESCRIPTOR_HANDLE))
       original[SLOT_CREATE_UAV])(self, resource, counter, desc, dest);
  if (check_removed(self, "CreateUnorderedAccessView")) {
    if (desc)
      report("  UAV desc: format %d dimension %d u0 %u u1 %u u2 %u u3 %u", desc->Format, desc->ViewDimension,
             desc->Texture2DArray.MipSlice, desc->Texture2DArray.FirstArraySlice, desc->Texture2DArray.ArraySize,
             desc->Texture2DArray.PlaneSlice);
    else
      report("  UAV desc: NULL");
    log_resource(resource);
    report("  counter %p dest %#lx", counter, (unsigned long)dest.ptr);
  }
}

static void hook_srv(void *self, void *resource, const D3D12_SHADER_RESOURCE_VIEW_DESC *desc,
                     D3D12_CPU_DESCRIPTOR_HANDLE dest) {
  ((void (*)(void *, void *, const D3D12_SHADER_RESOURCE_VIEW_DESC *, D3D12_CPU_DESCRIPTOR_HANDLE))
       original[SLOT_CREATE_SRV])(self, resource, desc, dest);
  if (check_removed(self, "CreateShaderResourceView")) {
    if (desc)
      report("  SRV desc: format %d dimension %d mapping %#x u0 %u u1 %u u2 %u u3 %u", desc->Format,
             desc->ViewDimension, desc->Shader4ComponentMapping, desc->Texture2DArray.MostDetailedMip,
             desc->Texture2DArray.MipLevels, desc->Texture2DArray.FirstArraySlice, desc->Texture2DArray.ArraySize);
    log_resource(resource);
    report("  dest %#lx", (unsigned long)dest.ptr);
  }
}

#define HOOK_GENERIC(slot, name)                                                                     \
  static uintptr_t hook_##slot(void *self, uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d, uintptr_t e) { \
    uintptr_t r = ((uintptr_t (*)(void *, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t))original[slot])( \
        self, a, b, c, d, e);                                                                         \
    if (check_removed(self, name)) report("  args %#lx %#lx %#lx %#lx %#lx -> %#lx", a, b, c, d, e, r); \
    return r;                                                                                         \
  }

HOOK_GENERIC(SLOT_CREATE_DESCRIPTOR_HEAP, "CreateDescriptorHeap")
HOOK_GENERIC(SLOT_CREATE_RTV, "CreateRenderTargetView")
HOOK_GENERIC(SLOT_CREATE_DSV, "CreateDepthStencilView")
HOOK_GENERIC(SLOT_CREATE_SAMPLER, "CreateSampler")
HOOK_GENERIC(SLOT_COPY_DESCRIPTORS_SIMPLE, "CopyDescriptorsSimple")

/* CopyDescriptors has 9 arguments; forward the stack ones too. */
static void hook_copy_descriptors(void *self, UINT dst_ranges, const D3D12_CPU_DESCRIPTOR_HANDLE *dst_starts,
                                  const UINT *dst_sizes, UINT src_ranges, const D3D12_CPU_DESCRIPTOR_HANDLE *src_starts,
                                  const UINT *src_sizes, D3D12_DESCRIPTOR_HEAP_TYPE type) {
  ((void (*)(void *, UINT, const D3D12_CPU_DESCRIPTOR_HANDLE *, const UINT *, UINT, const D3D12_CPU_DESCRIPTOR_HANDLE *,
             const UINT *, D3D12_DESCRIPTOR_HEAP_TYPE))original[SLOT_COPY_DESCRIPTORS])(
      self, dst_ranges, dst_starts, dst_sizes, src_ranges, src_starts, src_sizes, type);
  if (check_removed(self, "CopyDescriptors")) report("  dst ranges %u src ranges %u type %d", dst_ranges, src_ranges, type);
}

extern "C" void ika_dred_hook_device(void *device) {
  if (!enabled() || original[SLOT_CREATE_UAV]) return;
  void **vtable = *(void ***)device;
  long page = sysconf(_SC_PAGESIZE);
  uintptr_t start = (uintptr_t)vtable & ~(uintptr_t)(page - 1);
  uintptr_t end = ((uintptr_t)(vtable + SLOT_COUNT_HOOKED) + page - 1) & ~(uintptr_t)(page - 1);
  if (mprotect((void *)start, end - start, PROT_READ | PROT_WRITE)) {
    report("cannot hook the D3D12 device vtable");
    return;
  }
  struct {
    int slot;
    void *hook;
  } hooks[] = {
      {SLOT_CREATE_DESCRIPTOR_HEAP, (void *)hook_SLOT_CREATE_DESCRIPTOR_HEAP},
      {SLOT_CREATE_SRV, (void *)hook_srv},
      {SLOT_CREATE_UAV, (void *)hook_uav},
      {SLOT_CREATE_RTV, (void *)hook_SLOT_CREATE_RTV},
      {SLOT_CREATE_DSV, (void *)hook_SLOT_CREATE_DSV},
      {SLOT_CREATE_SAMPLER, (void *)hook_SLOT_CREATE_SAMPLER},
      {SLOT_COPY_DESCRIPTORS, (void *)hook_copy_descriptors},
      {SLOT_COPY_DESCRIPTORS_SIMPLE, (void *)hook_SLOT_COPY_DESCRIPTORS_SIMPLE},
  };
  for (auto &h : hooks) {
    original[h.slot] = vtable[h.slot];
    vtable[h.slot] = h.hook;
  }
  report("hooked D3D12 device vtable %p", (void *)vtable);
}
