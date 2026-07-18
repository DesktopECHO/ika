# Gfxstream Memory Retention Mitigation

## Summary

Repeated Asphalt launches on an Ika VM running on an Apple Silicon host caused
the host graphics stack's resident memory to grow and not return to its previous
level after the game exited. The growth occurred while the VM remained running;
the existing renderer-shutdown cleanup therefore could not address it.

The fault was a combination of lifetime and retention problems along the
host-visible Vulkan allocation path:

1. Gfxstream created a fresh udmabuf object for each host-visible allocation.
2. Ownership of that allocation was split between the host `VkDeviceMemory`
   object and the virtio-gpu blob exported to crosvm, but no common lifetime
   token described when both users were finished.
3. Crosvm imported an already-mappable DMA-BUF into a second Vulkan allocation
   merely to obtain a CPU mapping. This introduced another driver-controlled
   descriptor and allocation lifetime.
4. Even after graphics objects were destroyed, glibc retained free pages in
   the many arenas created by short-lived gfxstream render threads.

The result behaved like a leak from the host's point of view even when portions
of the graphics object graph had been released. The solution makes ownership
explicit, removes the redundant Vulkan import, reuses external-memory objects
instead of continually creating new identities, and trims allocator residue at
the correct cleanup boundary.

No Mesa or kernel source changes are required.

## Scope and constraints

The affected configuration is the Apple Silicon 16 KiB-page host path using
gfxstream and udmabuf-backed host-visible Vulkan memory. Asphalt was used as the
high-churn reproducer, but the problem applies to workloads which repeatedly
create and destroy guest graphics processes with large host-visible allocations.

The design deliberately preserves other configurations:

- Opaque Vulkan external-memory handles continue through crosvm's Vulkano
  import path.
- The pool is used only by gfxstream's udmabuf allocation path.
- The glibc tuning is injected only for Apple Silicon 16 KiB-page gfxstream
  launches.
- Existing caller-provided `GLIBC_TUNABLES` values are retained and take
  precedence for tunables the caller already set.

## Background

Commit `c0d698a5e` added defensive cleanup of Rutabaga and Vulkan objects when a
VM shuts down. That is still useful, but it acts at renderer teardown. Asphalt
exits while the VM and renderer continue running, so fixing VM shutdown cannot
bound memory accumulated across game launches.

This change moves the relevant lifetime handling to per-allocation and
per-process cleanup boundaries.

## Root cause

### Split external-memory ownership

Gfxstream imports a memfd-backed udmabuf as host Vulkan memory and also exports
the same backing through a virtio-gpu blob. Either the Vulkan allocation or the
blob resource can remain live after the other is destroyed. Previously there
was no single ownership object spanning both paths, so gfxstream could not know
when an allocation was safe to reuse.

### Repeated DMA-BUF identities

The graphics driver can retain metadata or imports associated with a DMA-BUF
after the guest allocation that initiated them has gone away. Creating new
udmabufs on every launch therefore permits retention to grow with every launch.
Gfxstream cannot reliably force all external driver bookkeeping to disappear,
and changing Mesa or the kernel was outside the allowed scope.

### Redundant crosvm Vulkan import

The exported udmabuf is already a file-backed, directly mappable DMA-BUF.
Crosvm nevertheless passed it through Vulkano's Vulkan import path to obtain a
CPU address. This added a second Vulkan device-memory lifetime and allowed an
imported descriptor to keep the backing pages pinned beyond guest unmap.

### Allocator residency

Gfxstream performs cleanup work across many render threads. Glibc's default
multi-arena allocator can keep pages belonging to now-free allocations resident
in per-thread arenas. This accounts for residual RSS that is not a live Vulkan
or virtio-gpu object and therefore is not fixed by object destruction alone.

## Implementation

### 1. Exact-size udmabuf pool

`PATCH.gfxstream.pool-host-visible-udmabufs.patch` adds a process-local pool to
`UdmabufCreator`.

- A new allocation size creates one memfd/udmabuf pair.
- A later allocation of exactly the same size reuses that pair.
- Exact-size matching preserves Vulkan DMA-BUF import-size requirements.
- The pool grows to the workload's concurrent high-water mark rather than with
  the number of guest process launches.
- A 250 ms quarantine separates final release from reuse, avoiding a race with
  crosvm's final duplicated descriptor close.

Pooling is intentional retention: it converts unbounded per-launch growth into
bounded reuse. Pool entries remain available until gfxstream exits.

### 2. Shared lifetime token

Each pooled entry returns a shared lease along with its descriptor. References
to that lease travel through both relevant ownership paths:

- `MemoryInfo` retains it for the host `VkDeviceMemory` object.
- `BlobDescriptorInfo` retains it for the exported virtio-gpu blob resource.

The lease releases the pool entry only after both references are destroyed.
This restores the lifetime information that was missing at the ownership split
and prevents reuse while either side can still expose the memory.

### 3. Direct crosvm DMA-BUF mapping

`PATCH.vm_control-map-dmabuf-directly.patch` detects
`RUTABAGA_HANDLE_TYPE_MEM_DMABUF` in `VmMemorySource::Vulkan` and maps it with
`mmap` through crosvm's descriptor mapping helper. Unregistering the guest
memory now drops a normal `MemoryMapping` and its retained descriptor without
creating a second Vulkan import.

Opaque Vulkan handles still use the existing gralloc/Vulkano path.

### 4. Cleanup-boundary allocator trim

Once gfxstream's cleanup worker has joined the guest process render threads,
removed its GL/Vulkan objects, and released its `ProcessResources`, it calls
`malloc_trim(0)` on the udmabuf feature path. This ordering matters: trimming
before the last per-process owners are released would leave the largest free
blocks in the arenas.

Ika also launches the affected renderer with conservative glibc defaults:

```text
glibc.malloc.arena_max=4
glibc.malloc.trim_threshold=131072
```

Limiting arena proliferation reduces the amount of free memory that can remain
resident between cleanup events. The launcher does not overwrite either value
when the user supplied it explicitly.

## Expected behavior

During a first run, host graphics memory can still increase as the workload
establishes its pool and driver high-water marks. Later launches using the same
allocation sizes should reuse those external-memory objects instead of adding a
new retained set. Memory usage should therefore plateau near the workload's
high-water mark rather than increase roughly once per launch.

Some retained memory is expected and is not considered a regression:

- pooled backing at the maximum concurrent allocation demand;
- driver caches that are bounded by reuse of the same DMA-BUF identities; and
- normal renderer, shader, and allocator caches.

## Validation

On 2026-07-17, the complete patched dependency graph was built from the Ryzen9
working copy at base commit `12597a6b7` with the repository's pinned Bazel
8.5.1. The optimized `@crosvm_bin//:crosvm__crosvm` and
`@gfxstream//host:gfxstream_backend` targets both completed successfully (684
local actions). `tools/ika` also passed `bash -n`, and the complete change set
passed `git diff --check`.

Runtime validation is performed in layers:

- repeated guest process teardown exercises release by both Vulkan-memory and
  virtio-blob owners before a pool entry becomes reusable; and
- repeated Asphalt launches are checked for a plateau after warm-up, rather
  than expecting all graphics RSS to return to the pre-launch baseline.

For runtime verification, observe both host RSS and DMA-BUF/fd counts over at
least three launch/exit cycles. A rising first-cycle high-water mark is normal;
continued near-linear growth after equivalent later cycles is not.

## Risks and limitations

- Exact-size pooling is conservative. Workloads using many distinct allocation
  sizes can create more pool entries, though each recurring size is still
  bounded by peak concurrency.
- The quarantine is a safety margin, not a synchronization protocol with the
  VMM. The shared lease supplies the actual in-process ownership guarantee.
- `malloc_trim` is glibc-specific and compiled out on other C libraries.
- This mitigation cannot eliminate arbitrary caches inside external drivers;
  it bounds their growth by reusing external-memory identities.
- Pool entries are reclaimed when gfxstream exits, not during idle periods.

## Changed files

- `base/cvd/build_external/gfxstream/PATCH.gfxstream.pool-host-visible-udmabufs.patch`
- `base/cvd/build_external/gfxstream/gfxstream.MODULE.bazel`
- `base/cvd/build_external/crosvm/PATCH.vm_control-map-dmabuf-directly.patch`
- `base/cvd/build_external/crosvm/crosvm.MODULE.bazel`
- `base/cvd/build_external/crosvm/README.md`
- `tools/ika`
