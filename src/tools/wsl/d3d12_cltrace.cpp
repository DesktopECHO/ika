// Command-list tracing for the libd3d12.so shim: with IKA_D3D12_DRED=1 and
// IKA_D3D12_CLTRACE=1, records the D3D12 commands recorded into each command
// list (the last 256 since its Reset, with each call's first argument after
// the list) and reports them to stderr (crosvm's log) and /tmp/ika-dred.log
// when a list fails to Close, or when an ExecuteCommandLists call removes the
// device. D3D12 on WSL has no debug layer, so a command it rejects otherwise
// only shows up as DXGI_ERROR_INVALID_CALL removing the device at submission.
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wsl/winadapter.h>
#include <directx/d3d12.h>

static void report(const char *fmt, ...) {
  char line[1024];
  va_list args;
  va_start(args, fmt);
  vsnprintf(line, sizeof(line), fmt, args);
  va_end(args);
  fprintf(stderr, "ika cltrace: %s\n", line);
  if (FILE *f = fopen("/tmp/ika-dred.log", "a")) {
    fprintf(f, "cltrace: %s\n", line);
    fclose(f);
  }
}

/* The vtable slot of a virtual method: under the Itanium C++ ABI a pointer to
 * a virtual member function holds 1 + the slot's byte offset. */
template <typename T> static int slot_of(T member) {
  union {
    T pointer;
    uintptr_t words[2];
  } u;
  memset(&u, 0, sizeof(u));
  u.pointer = member;
  return (int)((u.words[0] - 1) / sizeof(void *));
}

enum { MAX_SLOTS = 128 };
static const char *slot_names[MAX_SLOTS];
static int slot_close, slot_reset, slot_barrier = -1;

/* The last slot of each ID3D12GraphicsCommandList version, [1] for the base. */
static int last_slot[10];

static void name_slots() {
#define M(iface, method) slot_names[slot_of(&iface::method)] = #method
  M(ID3D12GraphicsCommandList, Close);
  M(ID3D12GraphicsCommandList, Reset);
  M(ID3D12GraphicsCommandList, ClearState);
  M(ID3D12GraphicsCommandList, DrawInstanced);
  M(ID3D12GraphicsCommandList, DrawIndexedInstanced);
  M(ID3D12GraphicsCommandList, Dispatch);
  M(ID3D12GraphicsCommandList, CopyBufferRegion);
  M(ID3D12GraphicsCommandList, CopyTextureRegion);
  M(ID3D12GraphicsCommandList, CopyResource);
  M(ID3D12GraphicsCommandList, CopyTiles);
  M(ID3D12GraphicsCommandList, ResolveSubresource);
  M(ID3D12GraphicsCommandList, IASetPrimitiveTopology);
  M(ID3D12GraphicsCommandList, RSSetViewports);
  M(ID3D12GraphicsCommandList, RSSetScissorRects);
  M(ID3D12GraphicsCommandList, OMSetBlendFactor);
  M(ID3D12GraphicsCommandList, OMSetStencilRef);
  M(ID3D12GraphicsCommandList, SetPipelineState);
  M(ID3D12GraphicsCommandList, ResourceBarrier);
  M(ID3D12GraphicsCommandList, ExecuteBundle);
  M(ID3D12GraphicsCommandList, SetDescriptorHeaps);
  M(ID3D12GraphicsCommandList, SetComputeRootSignature);
  M(ID3D12GraphicsCommandList, SetGraphicsRootSignature);
  M(ID3D12GraphicsCommandList, SetComputeRootDescriptorTable);
  M(ID3D12GraphicsCommandList, SetGraphicsRootDescriptorTable);
  M(ID3D12GraphicsCommandList, SetComputeRoot32BitConstant);
  M(ID3D12GraphicsCommandList, SetGraphicsRoot32BitConstant);
  M(ID3D12GraphicsCommandList, SetComputeRoot32BitConstants);
  M(ID3D12GraphicsCommandList, SetGraphicsRoot32BitConstants);
  M(ID3D12GraphicsCommandList, SetComputeRootConstantBufferView);
  M(ID3D12GraphicsCommandList, SetGraphicsRootConstantBufferView);
  M(ID3D12GraphicsCommandList, SetComputeRootShaderResourceView);
  M(ID3D12GraphicsCommandList, SetGraphicsRootShaderResourceView);
  M(ID3D12GraphicsCommandList, SetComputeRootUnorderedAccessView);
  M(ID3D12GraphicsCommandList, SetGraphicsRootUnorderedAccessView);
  M(ID3D12GraphicsCommandList, IASetIndexBuffer);
  M(ID3D12GraphicsCommandList, IASetVertexBuffers);
  M(ID3D12GraphicsCommandList, SOSetTargets);
  M(ID3D12GraphicsCommandList, OMSetRenderTargets);
  M(ID3D12GraphicsCommandList, ClearDepthStencilView);
  M(ID3D12GraphicsCommandList, ClearRenderTargetView);
  M(ID3D12GraphicsCommandList, ClearUnorderedAccessViewUint);
  M(ID3D12GraphicsCommandList, ClearUnorderedAccessViewFloat);
  M(ID3D12GraphicsCommandList, DiscardResource);
  M(ID3D12GraphicsCommandList, BeginQuery);
  M(ID3D12GraphicsCommandList, EndQuery);
  M(ID3D12GraphicsCommandList, ResolveQueryData);
  M(ID3D12GraphicsCommandList, SetPredication);
  M(ID3D12GraphicsCommandList, SetMarker);
  M(ID3D12GraphicsCommandList, BeginEvent);
  M(ID3D12GraphicsCommandList, EndEvent);
  M(ID3D12GraphicsCommandList, ExecuteIndirect);
  last_slot[1] = slot_of(&ID3D12GraphicsCommandList::ExecuteIndirect);
  M(ID3D12GraphicsCommandList1, AtomicCopyBufferUINT);
  M(ID3D12GraphicsCommandList1, AtomicCopyBufferUINT64);
  M(ID3D12GraphicsCommandList1, OMSetDepthBounds);
  M(ID3D12GraphicsCommandList1, SetSamplePositions);
  M(ID3D12GraphicsCommandList1, ResolveSubresourceRegion);
  M(ID3D12GraphicsCommandList1, SetViewInstanceMask);
  last_slot[2] = slot_of(&ID3D12GraphicsCommandList1::SetViewInstanceMask);
  M(ID3D12GraphicsCommandList2, WriteBufferImmediate);
  last_slot[3] = slot_of(&ID3D12GraphicsCommandList2::WriteBufferImmediate);
  M(ID3D12GraphicsCommandList3, SetProtectedResourceSession);
  last_slot[4] = slot_of(&ID3D12GraphicsCommandList3::SetProtectedResourceSession);
  M(ID3D12GraphicsCommandList4, BeginRenderPass);
  M(ID3D12GraphicsCommandList4, EndRenderPass);
  M(ID3D12GraphicsCommandList4, InitializeMetaCommand);
  M(ID3D12GraphicsCommandList4, ExecuteMetaCommand);
  M(ID3D12GraphicsCommandList4, BuildRaytracingAccelerationStructure);
  M(ID3D12GraphicsCommandList4, EmitRaytracingAccelerationStructurePostbuildInfo);
  M(ID3D12GraphicsCommandList4, CopyRaytracingAccelerationStructure);
  M(ID3D12GraphicsCommandList4, SetPipelineState1);
  M(ID3D12GraphicsCommandList4, DispatchRays);
  last_slot[5] = slot_of(&ID3D12GraphicsCommandList4::DispatchRays);
  M(ID3D12GraphicsCommandList5, RSSetShadingRate);
  M(ID3D12GraphicsCommandList5, RSSetShadingRateImage);
  last_slot[6] = slot_of(&ID3D12GraphicsCommandList5::RSSetShadingRateImage);
  M(ID3D12GraphicsCommandList6, DispatchMesh);
  last_slot[7] = slot_of(&ID3D12GraphicsCommandList6::DispatchMesh);
  M(ID3D12GraphicsCommandList7, Barrier);
  last_slot[8] = slot_of(&ID3D12GraphicsCommandList7::Barrier);
  M(ID3D12GraphicsCommandList8, OMSetFrontAndBackStencilRef);
  last_slot[9] = slot_of(&ID3D12GraphicsCommandList8::OMSetFrontAndBackStencilRef);
#undef M
  slot_close = slot_of(&ID3D12GraphicsCommandList::Close);
  slot_barrier = slot_of(&ID3D12GraphicsCommandList7::Barrier);
  slot_reset = slot_of(&ID3D12GraphicsCommandList::Reset);
}

/* ---- Per-list call rings ---- */
enum { RING = 256, LISTS = 1024, DETAILS = 96, DETAIL_LEN = 200 };
struct ring {
  void *list;
  uint32_t count; /* calls since the last Reset */
  int32_t close_result;
  uint16_t slot[RING];
  uint64_t arg[RING];
  /* Barrier details: each line with the call number it belongs to. */
  uint32_t detail_count;
  uint32_t detail_call[DETAILS];
  char detail[DETAILS][DETAIL_LEN];
};
static ring rings[LISTS];
static pthread_mutex_t rings_lock = PTHREAD_MUTEX_INITIALIZER;

static ring *ring_for(void *list) {
  unsigned h = (unsigned)(((uintptr_t)list >> 4) * 2654435761u) % LISTS;
  for (unsigned i = 0; i < LISTS; i++) {
    ring *r = &rings[(h + i) % LISTS];
    void *owner = __atomic_load_n(&r->list, __ATOMIC_ACQUIRE);
    if (owner == list) return r;
    if (!owner) {
      pthread_mutex_lock(&rings_lock);
      owner = __atomic_load_n(&r->list, __ATOMIC_ACQUIRE);
      if (!owner) {
        r->count = 0;
        r->close_result = 0;
        r->detail_count = 0;
        __atomic_store_n(&r->list, list, __ATOMIC_RELEASE);
        owner = list;
      }
      pthread_mutex_unlock(&rings_lock);
      if (owner == list) return r;
    }
  }
  return nullptr;
}

static void record(void *list, int slot, uint64_t arg) {
  ring *r = ring_for(list);
  if (!r) return;
  uint32_t n = r->count++;
  r->slot[n % RING] = (uint16_t)slot;
  r->arg[n % RING] = arg;
}

static void add_detail(void *list, const char *fmt, ...) {
  ring *r = ring_for(list);
  if (!r) return;
  uint32_t d = r->detail_count++ % DETAILS;
  r->detail_call[d] = r->count ? r->count - 1 : 0;
  va_list args;
  va_start(args, fmt);
  vsnprintf(r->detail[d], DETAIL_LEN, fmt, args);
  va_end(args);
}

static void dump_details(ring *r, uint32_t from_call) {
  uint32_t n = r->detail_count;
  uint32_t first = n > DETAILS ? n - DETAILS : 0;
  for (uint32_t i = first; i < n; i++) {
    uint32_t d = i % DETAILS;
    if (r->detail_call[d] >= from_call) report("    %5u   %s", r->detail_call[d], r->detail[d]);
  }
}

static void dump_ring(void *list, unsigned last) {
  ring *r = ring_for(list);
  if (!r) {
    report("  list %p: not traced", list);
    return;
  }
  uint32_t n = r->count;
  uint32_t shown = n < last ? n : last;
  if (shown > RING) shown = RING;
  report("  list %p: %u calls since Reset, Close result %#x; last %u:", list, n, (unsigned)r->close_result, shown);
  for (uint32_t i = n - shown; i < n; i++) {
    int s = r->slot[i % RING];
    report("    %5u %s(%#llx)", i, s < MAX_SLOTS && slot_names[s] ? slot_names[s] : "?",
           (unsigned long long)r->arg[i % RING]);
  }
  report("  barrier details of those calls:");
  dump_details(r, n - shown);
}

/* ---- Command list vtables ---- */
struct list_vtable {
  void **vtable;
  int max_slot;
  void *original[MAX_SLOTS];
};
static list_vtable list_vtables[4];
static int list_vtable_count;
static pthread_mutex_t vtable_lock = PTHREAD_MUTEX_INITIALIZER;

static list_vtable *vtable_info(void *list) {
  void **vtable = *(void ***)list;
  int count = __atomic_load_n(&list_vtable_count, __ATOMIC_ACQUIRE);
  for (int i = 0; i < count; i++)
    if (list_vtables[i].vtable == vtable) return &list_vtables[i];
  return nullptr;
}

/* Called by every thunk: records the call and returns the original method. */
extern "C" __attribute__((visibility("hidden"))) void *ika_cl_record(void *list, long slot, uint64_t arg) {
  record(list, (int)slot, arg);
  return vtable_info(list)->original[slot];
}

/* A thunk per slot loads the slot into r11 and jumps here; this saves the
 * argument registers, calls ika_cl_record(list, slot, first argument) and
 * jumps to the original method with the registers as they were. */
extern "C" __attribute__((visibility("hidden"))) void ika_cl_common(void);
asm(R"(
  .text
  .p2align 4
  .type ika_cl_common, @function
ika_cl_common:
  pushq %rbp
  movq %rsp, %rbp
  subq $192, %rsp
  movq %rdi, 0(%rsp)
  movq %rsi, 8(%rsp)
  movq %rdx, 16(%rsp)
  movq %rcx, 24(%rsp)
  movq %r8, 32(%rsp)
  movq %r9, 40(%rsp)
  movq %rax, 56(%rsp)
  movdqa %xmm0, 64(%rsp)
  movdqa %xmm1, 80(%rsp)
  movdqa %xmm2, 96(%rsp)
  movdqa %xmm3, 112(%rsp)
  movdqa %xmm4, 128(%rsp)
  movdqa %xmm5, 144(%rsp)
  movdqa %xmm6, 160(%rsp)
  movdqa %xmm7, 176(%rsp)
  movq %r11, %rsi
  movq 8(%rsp), %rdx
  call ika_cl_record
  movq %rax, %r10
  movdqa 64(%rsp), %xmm0
  movdqa 80(%rsp), %xmm1
  movdqa 96(%rsp), %xmm2
  movdqa 112(%rsp), %xmm3
  movdqa 128(%rsp), %xmm4
  movdqa 144(%rsp), %xmm5
  movdqa 160(%rsp), %xmm6
  movdqa 176(%rsp), %xmm7
  movq 0(%rsp), %rdi
  movq 8(%rsp), %rsi
  movq 16(%rsp), %rdx
  movq 24(%rsp), %rcx
  movq 32(%rsp), %r8
  movq 40(%rsp), %r9
  movq 56(%rsp), %rax
  movq %rbp, %rsp
  popq %rbp
  jmpq *%r10
  .size ika_cl_common, .-ika_cl_common
)");

static unsigned char *thunks; /* 32 bytes per slot */

static bool make_thunks() {
  long page = sysconf(_SC_PAGESIZE);
  size_t size = (MAX_SLOTS * 32 + page - 1) & ~(size_t)(page - 1);
  void *mem = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (mem == MAP_FAILED) return false;
  unsigned char *p = (unsigned char *)mem;
  uint64_t common = (uint64_t)(uintptr_t)ika_cl_common;
  for (int s = 0; s < MAX_SLOTS; s++) {
    unsigned char *t = p + s * 32;
    uint64_t slot = (uint64_t)s;
    t[0] = 0x49; t[1] = 0xbb; memcpy(t + 2, &slot, 8);     /* movabs $slot, %r11 */
    t[10] = 0x49; t[11] = 0xba; memcpy(t + 12, &common, 8); /* movabs $common, %r10 */
    t[20] = 0x41; t[21] = 0xff; t[22] = 0xe2;               /* jmp *%r10 */
    memset(t + 23, 0xcc, 9);
  }
  if (mprotect(mem, size, PROT_READ | PROT_EXEC)) return false;
  thunks = p;
  return true;
}

static volatile int close_reports;

static HRESULT hook_close(void *self) {
  record(self, slot_close, 0);
  HRESULT hr = ((HRESULT(*)(void *))vtable_info(self)->original[slot_close])(self);
  ring *r = ring_for(self);
  if (r) r->close_result = (int32_t)hr;
  if (FAILED(hr) && __atomic_fetch_add(&close_reports, 1, __ATOMIC_RELAXED) < 5) {
    report("Close of command list %p failed: %#x", self, (unsigned)hr);
    dump_ring(self, 256);
  }
  return hr;
}

static HRESULT hook_reset(void *self, void *allocator, void *pipeline) {
  ring *r = ring_for(self);
  if (r) {
    r->count = 0;
    r->close_result = 0;
    r->detail_count = 0;
  }
  record(self, slot_reset, (uint64_t)(uintptr_t)allocator);
  return ((HRESULT(*)(void *, void *, void *))vtable_info(self)->original[slot_reset])(self, allocator, pipeline);
}

/* ID3D12Resource::GetDesc, slot 10; the Itanium C++ ABI passes the returned
 * struct's address first, before this. */
static void resource_desc(void *resource, D3D12_RESOURCE_DESC *desc) {
  typedef void (*get_desc_fn)(D3D12_RESOURCE_DESC *, void *);
  memset(desc, 0, sizeof(*desc));
  if (resource) ((get_desc_fn)(*(void ***)resource)[10])(desc, resource);
}

static void hook_barrier(void *self, UINT32 groups, const D3D12_BARRIER_GROUP *group) {
  record(self, slot_barrier, groups);
  for (UINT32 g = 0; g < groups && group; g++) {
    const D3D12_BARRIER_GROUP &bg = group[g];
    for (UINT32 i = 0; i < bg.NumBarriers; i++) {
      if (bg.Type == D3D12_BARRIER_TYPE_GLOBAL) {
        const D3D12_GLOBAL_BARRIER &b = bg.pGlobalBarriers[i];
        add_detail(self, "global sync %#x->%#x access %#x->%#x", b.SyncBefore, b.SyncAfter, b.AccessBefore,
                   b.AccessAfter);
      } else if (bg.Type == D3D12_BARRIER_TYPE_TEXTURE) {
        const D3D12_TEXTURE_BARRIER &b = bg.pTextureBarriers[i];
        D3D12_RESOURCE_DESC d;
        resource_desc(b.pResource, &d);
        add_detail(self,
                   "texture sync %#x->%#x access %#x->%#x layout %d->%d sub mip %u+%u array %u+%u plane %u+%u flags %#x"
                   " | res %p dim %d fmt %d %llux%u x%u mips %u flags %#x",
                   b.SyncBefore, b.SyncAfter, b.AccessBefore, b.AccessAfter, b.LayoutBefore, b.LayoutAfter,
                   b.Subresources.IndexOrFirstMipLevel, b.Subresources.NumMipLevels, b.Subresources.FirstArraySlice,
                   b.Subresources.NumArraySlices, b.Subresources.FirstPlane, b.Subresources.NumPlanes, b.Flags,
                   (void *)b.pResource, d.Dimension, d.Format, (unsigned long long)d.Width, d.Height,
                   d.DepthOrArraySize, d.MipLevels, d.Flags);
      } else if (bg.Type == D3D12_BARRIER_TYPE_BUFFER) {
        const D3D12_BUFFER_BARRIER &b = bg.pBufferBarriers[i];
        add_detail(self, "buffer sync %#x->%#x access %#x->%#x res %p offset %llu size %llu", b.SyncBefore,
                   b.SyncAfter, b.AccessBefore, b.AccessAfter, (void *)b.pResource, (unsigned long long)b.Offset,
                   (unsigned long long)b.Size);
      }
    }
  }
  ((void (*)(void *, UINT32, const D3D12_BARRIER_GROUP *))vtable_info(self)->original[slot_barrier])(self, groups,
                                                                                                    group);
}

static bool unprotect(void **vtable, int slots) {
  long page = sysconf(_SC_PAGESIZE);
  uintptr_t start = (uintptr_t)vtable & ~(uintptr_t)(page - 1);
  uintptr_t end = ((uintptr_t)(vtable + slots) + page - 1) & ~(uintptr_t)(page - 1);
  return mprotect((void *)start, end - start, PROT_READ | PROT_WRITE) == 0;
}

/* The newest ID3D12GraphicsCommandList version the list implements. */
static int list_version(void *list) {
  auto *unknown = static_cast<IUnknown *>(list);
  const IID *iids[] = {&IID_ID3D12GraphicsCommandList,  &IID_ID3D12GraphicsCommandList1,
                       &IID_ID3D12GraphicsCommandList2, &IID_ID3D12GraphicsCommandList3,
                       &IID_ID3D12GraphicsCommandList4, &IID_ID3D12GraphicsCommandList5,
                       &IID_ID3D12GraphicsCommandList6, &IID_ID3D12GraphicsCommandList7,
                       &IID_ID3D12GraphicsCommandList8};
  for (int v = 9; v >= 1; v--) {
    void *out = nullptr;
    if (SUCCEEDED(unknown->QueryInterface(*iids[v - 1], &out)) && out) {
      static_cast<IUnknown *>(out)->Release();
      return v;
    }
  }
  return 0;
}

static void hook_list(void *list) {
  if (!list || vtable_info(list)) return;
  pthread_mutex_lock(&vtable_lock);
  void **vtable = *(void ***)list;
  bool known = false;
  for (int i = 0; i < list_vtable_count; i++)
    if (list_vtables[i].vtable == vtable) known = true;
  int version = known ? 0 : list_version(list);
  if (!known && version && list_vtable_count < 4) {
    int max_slot = last_slot[version];
    list_vtable *v = &list_vtables[list_vtable_count];
    if (max_slot < MAX_SLOTS && unprotect(vtable, max_slot + 1)) {
      v->vtable = vtable;
      v->max_slot = max_slot;
      for (int s = 0; s <= max_slot; s++) v->original[s] = vtable[s];
      __atomic_store_n(&list_vtable_count, list_vtable_count + 1, __ATOMIC_RELEASE);
      for (int s = 0; s <= max_slot; s++) {
        if (!slot_names[s]) continue;
        if (s == slot_close) vtable[s] = (void *)hook_close;
        else if (s == slot_barrier) vtable[s] = (void *)hook_barrier;
        else if (s == slot_reset) vtable[s] = (void *)hook_reset;
        else vtable[s] = thunks + s * 32;
      }
      report("tracing command list vtable %p (ID3D12GraphicsCommandList%d, slots up to %d)", (void *)vtable,
             version - 1, max_slot);
    }
  }
  pthread_mutex_unlock(&vtable_lock);
}

/* ---- Device and queue hooks ---- */
static void *device_original[MAX_SLOTS];
static int slot_create_queue, slot_create_list, slot_create_list1;

static struct {
  void *queue;
  ID3D12Device *device;
} queues[256];
static int queue_count;
static void *execute_original;
static int slot_execute;
static volatile int execute_reported;

static void hook_execute(void *self, UINT count, ID3D12CommandList *const *lists) {
  ((void (*)(void *, UINT, ID3D12CommandList *const *))execute_original)(self, count, lists);
  if (execute_reported) return;
  ID3D12Device *device = nullptr;
  int n = __atomic_load_n(&queue_count, __ATOMIC_ACQUIRE);
  for (int i = 0; i < n && !device; i++)
    if (queues[i].queue == self) device = queues[i].device;
  if (!device) return;
  HRESULT reason = device->GetDeviceRemovedReason();
  if (SUCCEEDED(reason) || __atomic_exchange_n(&execute_reported, 1, __ATOMIC_RELAXED)) return;
  report("ExecuteCommandLists on queue %p (device %p) removed the device: reason %#x; %u lists:", self,
         (void *)device, (unsigned)reason, count);
  for (UINT i = 0; i < count; i++) dump_ring(lists[i], 48);
}

static void hook_queue(void *queue, ID3D12Device *device) {
  if (!queue) return;
  int n = __atomic_load_n(&queue_count, __ATOMIC_ACQUIRE);
  if (n < 256) {
    queues[n].queue = queue;
    queues[n].device = device;
    __atomic_store_n(&queue_count, n + 1, __ATOMIC_RELEASE);
  }
  void **vtable = *(void ***)queue;
  if (vtable[slot_execute] == (void *)hook_execute) return;
  pthread_mutex_lock(&vtable_lock);
  if (vtable[slot_execute] != (void *)hook_execute && unprotect(vtable, slot_execute + 1)) {
    execute_original = vtable[slot_execute];
    vtable[slot_execute] = (void *)hook_execute;
    report("tracing ExecuteCommandLists of queue vtable %p", (void *)vtable);
  }
  pthread_mutex_unlock(&vtable_lock);
}

static HRESULT hook_create_queue(void *self, const D3D12_COMMAND_QUEUE_DESC *desc, const IID *riid, void **out) {
  HRESULT hr = ((HRESULT(*)(void *, const D3D12_COMMAND_QUEUE_DESC *, const IID *, void **))
                    device_original[slot_create_queue])(self, desc, riid, out);
  if (SUCCEEDED(hr) && out) hook_queue(*out, static_cast<ID3D12Device *>(self));
  return hr;
}

static HRESULT hook_create_list(void *self, UINT node, D3D12_COMMAND_LIST_TYPE type, void *allocator,
                                void *pipeline, const IID *riid, void **out) {
  HRESULT hr = ((HRESULT(*)(void *, UINT, D3D12_COMMAND_LIST_TYPE, void *, void *, const IID *, void **))
                    device_original[slot_create_list])(self, node, type, allocator, pipeline, riid, out);
  if (SUCCEEDED(hr) && out) {
    hook_list(*out);
    record(*out, slot_reset, (uint64_t)(uintptr_t)allocator);
  }
  return hr;
}

static HRESULT hook_create_list1(void *self, UINT node, D3D12_COMMAND_LIST_TYPE type, D3D12_COMMAND_LIST_FLAGS flags,
                                 const IID *riid, void **out) {
  HRESULT hr = ((HRESULT(*)(void *, UINT, D3D12_COMMAND_LIST_TYPE, D3D12_COMMAND_LIST_FLAGS, const IID *, void **))
                    device_original[slot_create_list1])(self, node, type, flags, riid, out);
  if (SUCCEEDED(hr) && out) hook_list(*out);
  return hr;
}

extern "C" void ika_cltrace_hook_device(void *device) {
  const char *v = getenv("IKA_D3D12_CLTRACE");
  if (!v || v[0] != '1' || thunks) return;
  name_slots();
  slot_create_queue = slot_of(&ID3D12Device::CreateCommandQueue);
  slot_create_list = slot_of(&ID3D12Device::CreateCommandList);
  slot_create_list1 = slot_of(&ID3D12Device4::CreateCommandList1);
  slot_execute = slot_of(&ID3D12CommandQueue::ExecuteCommandLists);
  if (!make_thunks()) {
    report("cannot make the call thunks");
    return;
  }
  void *device4 = nullptr;
  bool has_list1 = SUCCEEDED(static_cast<IUnknown *>(device)->QueryInterface(IID_ID3D12Device4, &device4));
  if (device4) static_cast<IUnknown *>(device4)->Release();
  void **vtable = *(void ***)device;
  int top = has_list1 ? slot_create_list1 : slot_create_list;
  if (top >= MAX_SLOTS || !unprotect(vtable, top + 1)) {
    report("cannot hook the device's command list creation");
    return;
  }
  device_original[slot_create_queue] = vtable[slot_create_queue];
  device_original[slot_create_list] = vtable[slot_create_list];
  vtable[slot_create_queue] = (void *)hook_create_queue;
  vtable[slot_create_list] = (void *)hook_create_list;
  if (has_list1) {
    device_original[slot_create_list1] = vtable[slot_create_list1];
    vtable[slot_create_list1] = (void *)hook_create_list1;
  }
  report("tracing command lists of device vtable %p (CreateCommandQueue %d, CreateCommandList %d, CreateCommandList1 %d, "
         "ExecuteCommandLists %d, Close %d)",
         (void *)vtable, slot_create_queue, slot_create_list, has_list1 ? slot_create_list1 : -1, slot_execute,
         slot_close);
}
