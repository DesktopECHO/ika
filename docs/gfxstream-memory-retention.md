# Gfxstream Memory Retention Mitigation

## Summary

Repeated Asphalt launches on an Ika VM running on an Apple Silicon host caused
the host graphics stack's resident memory to grow without returning to its previous
level after the game exited. The growth occurred while the VM remained running;
the existing renderer-shutdown cleanup therefore could not address it.

The fault was a combination of lifetime and retention problems along the
host-visible Vulkan allocation path:

1. Gfxstream created a fresh udmabuf object for each host-visible allocation.
   Multiple `VkEmulation` instances can be created during one renderer process,
   so reuse scoped to one instance cannot bound cross-process kernel retention.
2. Ownership of each allocation was split between the host `VkDeviceMemory`
   object and the virtio-gpu blob exported to crosvm, but no common lifetime
   token described when both users were finished.
3. After renderer exit, affected Asahi kernels retained a final DMA-BUF
   attachment for each imported udmabuf. That attachment pins the memfd folios
   and survives crosvm, gfxstream, the desktop session, and even an Asahi module
   unload/reload.
4. Even after graphics objects were destroyed, glibc retained free pages in
   the many arenas created by short-lived gfxstream render threads.

The result behaved like a leak from the host's point of view even when portions
of the graphics object graph had been released. The solution makes ownership
explicit, reuses external-memory objects through one renderer-wide pool instead
of continually creating new identities, carries that pool's backing identities
across renderer restarts through a small per-user broker, and trims allocator
residue at the correct cleanup boundary.

No Mesa or kernel source changes are required.

### Mesa 26.1.5 and guest-kernel review

The graphics-stack upgrade on 2026-07-20 does not make these mitigations
obsolete. Mesa 26.1.5 and Linux 6.12.74 run inside the Android guest, whereas
the retained DMA-BUF attachment is owned by the host Honeykrisp/Asahi path.
The pinned host gfxstream revision, Fedora's Honeykrisp Mesa 26.1.4, and Asahi
7.0.13 kernel remain in that path. The bundled Mesa 26.1.5 Lavapipe ICD is a
software fallback and does not replace Honeykrisp on the accelerated path.
Retain the pooling, broker, shared lease, allocator trim, Rutabaga drain, and
defensive Vulkan teardown until an A/B kernel-accounting test on a newer host
stack shows that closing the last userspace descriptor also removes the Apple
GPU attachment.

A stopped-VM check during that review found 564 orphaned udmabufs totaling
2,565,439,488 bytes on the current Asahi 7.0.13 host. The sampled objects each
still listed `406400000.gpu` as their sole attachment after the broker had been
stopped, directly confirming that the current host kernel still needs identity
preservation and reuse.

## Scope and constraints

The affected configuration is the Apple Silicon 16 KiB-page host path using
gfxstream and udmabuf-backed host-visible Vulkan memory. Asphalt was used as the
high-churn reproducer, but the problem applies to workloads that repeatedly
create and destroy guest graphics processes with large host-visible allocations.

The design deliberately preserves other configurations:

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

At renderer teardown gfxstream explicitly destroys the guest Vulkan devices,
instances, and its own host Vulkan device. Runtime logs confirmed those paths
completed successfully for Asphalt. The remaining udmabufs nevertheless each
held one or more attachments to `406400000.gpu`, with no crosvm or desktop DRM
client alive. Closing every desktop DRM client and unloading/reloading the
`asahi` module did not release them. This distinguishes the kernel-retained
attachment from incomplete userspace Vulkan cleanup.

### Allocator residency

Gfxstream performs cleanup work across many render threads. Glibc's default
multi-arena allocator can keep pages belonging to now-free allocations resident
in per-thread arenas. This accounts for residual RSS that is not a live Vulkan
or virtio-gpu object and therefore is not fixed by object destruction alone.

## Implementation

### 1. Exact-size udmabuf pool

`PATCH.gfxstream.pool-host-visible-udmabufs.patch` adds one process-wide pool
shared by every `UdmabufCreator` in the renderer. This scope is essential:
gfxstream can create several `VkEmulation` objects, and a pool owned by one of
those objects is destroyed too early to provide cross-process reuse.

- A new allocation size creates one memfd/udmabuf pair.
- A later allocation of exactly the same size reuses that pair.
- Exact-size matching preserves Vulkan DMA-BUF import-size requirements.
- The pool grows to the workload's concurrent high-water mark rather than with
  the number of guest process launches.
- A 250 ms quarantine separates final release from reuse, avoiding a race with
  crosvm's final duplicated descriptor close.

Pooling is intentional retention: it converts unbounded per-launch growth into
bounded reuse. Pool entries remain available until gfxstream exits.

### 2. Persistent cross-renderer broker

Renderer-local pooling alone cannot reuse an object after crosvm exits. On the
affected kernel, losing the last userspace descriptor also loses the only safe
way to identify and reuse the pinned backing even though the orphaned GPU
attachment keeps it physically resident.

`ika-udmabuf-broker` is therefore started once per user on the Apple Silicon
16 KiB gfxstream path and deliberately survives `ika stop`. It creates and owns
the original memfd/udmabuf pairs and passes duplicate descriptors to gfxstream
over a mode-0600 Unix `SOCK_SEQPACKET` socket. A renderer connection leases each
exact-size entry at most once; all its leases become available when that
connection closes. The next crosvm process receives the same kernel objects,
so repeated VM stop/start cycles reuse the already pinned pages rather than
adding another workload-sized allocation.

The protocol validates a fixed magic/version, allocation size and peer UID,
and passes descriptors with `SCM_RIGHTS`. If the broker is disabled or
unavailable, gfxstream safely falls back to its renderer-local allocation path.
`IKA_UDMABUF_BROKER=off` provides an explicit diagnostic override.

### 3. Shared lifetime token

Each pooled entry returns a shared lease along with its descriptor. References
to that lease travel through both relevant ownership paths:

- `MemoryInfo` retains it for the host `VkDeviceMemory` object.
- `BlobDescriptorInfo` retains it for the exported virtio-gpu blob resource.

The lease releases the pool entry only after both references are destroyed.
This restores the lifetime information that was missing at the ownership split
and prevents reuse while either side can still expose the memory.

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

During a first run after a host boot, host graphics memory can still increase as
the workload establishes its pool and driver high-water marks. Later launches
and later VM processes using the same allocation sizes reuse those
external-memory objects instead of adding a new retained set. Memory usage
therefore plateaus near the workload's high-water mark rather than increasing
once per game launch or once per Cuttlefish restart.

Some retained memory is expected and is not considered a regression:

- broker-owned backing at the maximum concurrent allocation demand;
- driver caches that are bounded by reuse of the same DMA-BUF identities; and
- normal renderer, shader, and allocator caches.

## Validation

On 2026-07-17, the complete patched dependency graph was built from the Ryzen9
working copy with the repository's pinned Bazel 8.5.1. The optimized
`@crosvm_bin//:crosvm__crosvm` and `@gfxstream//host:gfxstream_backend` targets
both completed successfully. The ARM64 gfxstream target was then built on the
affected host and installed for runtime testing. `tools/ika` also passed
`bash -n`, and the complete change set passed `git diff --check`.

### Kernel-accounting re-evaluation

Process RSS alone initially gave a misleading result. An early version scoped
the pool to one `UdmabufCreator`; its visible memfd names appeared to plateau,
but `/sys/kernel/debug/dma_buf/bufinfo` showed 565 retained udmabufs totaling
5,719,097,344 bytes after repeated launches. Gfxstream creates multiple
`VkEmulation` objects during the renderer lifetime, so those per-instance pools
were being destroyed and recreated. The GPU driver retained the old imports in
the kernel even after their userspace pools disappeared.

The installed design was changed to one pool shared by every
`UdmabufCreator` in the renderer. The host was rebooted to remove the pre-fix
kernel state, and five launch/force-stop cycles of Asphalt 9 were run. Samples
were collected after process cleanup:

| Stage | udmabuf objects | udmabuf bytes | crosvm anonymous PSS (KiB) |
| --- | ---: | ---: | ---: |
| VM boot | 154 | 236,929,024 | 502,352 |
| Cycle 1 | 191 | 1,735,950,336 | 705,200 |
| Cycle 2 | 192 | 1,736,015,872 | 872,176 |
| Cycle 3 | 192 | 1,736,015,872 | 812,560 |
| Cycle 4 | 192 | 1,736,015,872 | 1,028,320 |
| Cycle 5 | 192 | 1,736,015,872 | 741,216 |

The first cycle established the workload high-water mark. Cycle two added one
64 KiB object; cycles three through five added no udmabuf objects or bytes.
Ordinary DRM DMA-BUFs also reached a display-buffer high-water mark and then
decreased. Anonymous PSS fluctuated rather than increasing once per launch,
which is consistent with allocator and renderer caches rather than retained
per-launch backing.

The persistent broker was then validated from a clean host boot with four
complete Cuttlefish renderer lifetimes. Asphalt was cold-started and
force-stopped in each VM before stopping Cuttlefish. `Broker entries` counts
only persistent memfd/udmabuf pairs; the larger live `udmabuf objects` count
also includes 10-11 small crosvm gralloc objects which are released on stop.

| Stage | Broker entries | udmabuf objects | udmabuf bytes |
| --- | ---: | ---: | ---: |
| Host boot | 0 | 0 | 0 |
| VM 1 boot | 143 | 153 | 218,546,176 |
| VM 1 after Asphalt | 179 | 189 | 1,433,174,016 |
| VM 1 stopped | 179 | 179 | 1,433,010,176 |
| VM 2 after Asphalt | 187 | 197 | 1,755,971,584 |
| VM 2 stopped | 187 | 187 | 1,755,807,744 |
| VM 3 after Asphalt | 189 | 199 | 1,764,098,048 |
| VM 3 stopped | 189 | 189 | 1,763,934,208 |
| VM 4 after Asphalt | 189 | 199 | 1,764,098,048 |
| VM 4 stopped | 189 | 189 | 1,763,934,208 |

The shorter first run did not reach Asphalt's eventual allocation concurrency;
VM 2 added three 100 MiB entries, and VM 3 added two small 4 MiB-class entries.
VM 4 then reused the complete set: both the post-game and post-stop kernel
counts and bytes were bit-for-bit identical to VM 3. No second workload-sized
set was allocated for the new crosvm processes.

This kernel view also establishes the limit of a userspace-only solution. Before
the reboot, udmabufs retained by the Apple GPU stack survived renderer exit;
closing crosvm was not sufficient to reclaim them. A controlled test also
showed that punching a hole in the backing memfd is unsafe: the memfd begins
returning zero-filled replacement pages while the udmabuf continues exposing
the old pinned pages, splitting the CPU and GPU views. Without changing Mesa or
the kernel, the safe remedy is therefore to preserve and reuse the same kernel
objects and bound retention at the host-boot workload high-water mark.

True reclamation still requires a host reboot. The broker makes this explicit
in `ika stop` output: retained memory is preserved for the next VM, while a
reboot is identified as the reclamation boundary rather than suggesting that a
graphics-session restart can release the pages.

Runtime validation is performed in layers:

- repeated guest-process teardown exercises release by both Vulkan-memory and
  virtio-blob owners before a pool entry becomes reusable;
- repeated Asphalt launches are checked for a plateau after warm-up; and
- two complete start/Asphalt/stop cycles are checked for stable udmabuf object
  count and bytes, proving reuse across different crosvm processes.

For runtime verification, observe host RSS, `/proc/meminfo` kernel/shmem
counters, and `/sys/kernel/debug/dma_buf/bufinfo` over at least three
launch/exit cycles. A rising first-cycle high-water mark is normal; continued
near-linear growth in either process or kernel accounting after equivalent
later cycles is not.

## Risks and limitations

- Exact-size pooling is conservative. Workloads using many distinct allocation
  sizes can create more pool entries, though each recurring size is still
  bounded by peak concurrency.
- The broker deliberately keeps its high-water backing resident between VM
  runs. This is bounded retention, not reclamation; rebooting the host remains
  necessary when that memory must be returned immediately.
- If the broker is killed or crashes after the GPU imported its objects, the
  affected kernel can retain those objects without a reusable userspace handle.
  Ika therefore leaves the broker running until host shutdown and records its
  diagnostics in `~/ika/udmabuf-broker.log`.
- The quarantine is a safety margin, not a synchronization protocol with the
  VMM. The shared lease supplies the actual in-process ownership guarantee.
- `malloc_trim` is glibc-specific and compiled out on other C libraries.
- This mitigation cannot eliminate arbitrary caches inside external drivers;
  it bounds their growth by reusing external-memory identities across both
  guest-process and renderer-process lifetimes.

## Changed files

- `base/cvd/build_external/gfxstream/PATCH.gfxstream.pool-host-visible-udmabufs.patch`
- `base/cvd/build_external/gfxstream/PATCH.gfxstream.udmabuf-broker.patch`
- `base/cvd/build_external/gfxstream/gfxstream.MODULE.bazel`
- `tools/ika-udmabuf-broker`
- `docs/gfxstream-memory-retention.md`
- `tools/ika`
- Debian, RPM, and Arch packaging rules for the broker executable
