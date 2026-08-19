# Gfxstream Memory Retention Mitigation (removed)

## Status

**Removed on 2026-08-19.** The kernel defect this mitigation worked around is
fixed upstream, and the workaround itself had become harmful. This document is
kept as the historical record: it explains what the code did, why it existed,
and the evidence used to retire it.

The mitigation required **Asahi kernels without**
[AsahiLinux/linux#548](https://github.com/AsahiLinux/linux/pull/548) (merged
2026-07-25). Hosts still running such a kernel will see the original unbounded
growth; the remedy is to update the kernel, not to restore this code.

## The original problem

Repeated high-churn GPU workloads (Asphalt was the reproducer) on an Apple
Silicon host caused host graphics memory to grow without returning to its
previous level, because the affected Asahi kernels retained a final DMA-BUF
attachment for each imported udmabuf after the importing DRM file was closed.
That attachment pinned the memfd folios and survived crosvm, gfxstream, the
desktop session, and even an `asahi` module unload/reload. With no userspace
API able to detach it, the only userspace-side remedy was to avoid creating new
identities: pool udmabufs by exact size within the renderer, and preserve those
identities across renderer restarts through a per-user broker.

## Why it was removed

PR #548 fixes the root cause directly: `Vm::drop()` failed to drain the deferred
`drm_gpuvm_bo` cleanup list, so "a deferred `drm_gpuvm_bo` retains the imported
GEM and dma-buf after its DRM file is closed, leaving its backing pages pinned."
That is the exact behavior this mitigation existed to paper over.

This document previously set the retirement condition explicitly: retain the
mitigation *until an A/B kernel-accounting test on a newer host stack shows that
closing the last userspace descriptor also removes the Apple GPU attachment*.
That test was run on 2026-08-19 against Fedora Asahi Remix kernel
`7.1.6-400.asahi.fc44.aarch64+16k` and passed.

### Validation evidence

With the VM and broker fully stopped, `/sys/kernel/debug/dma_buf/bufinfo`:

| Metric | Pre-fix (Asahi 7.0.13, recorded in this doc) | Post-fix (7.1.6) |
| --- | ---: | ---: |
| Orphaned udmabuf objects | 564 | 1 |
| Retained bytes | 2,565,439,488 | 16,384 |
| Still attached to `…gpu` | yes (sole attachment) | 0 |

Killing the broker released its pinned pages immediately (host `shared` fell
2,887 MB → 964 MB; `available` rose 10,685 MB → 12,555 MB). Under the old
kernel those pages could not be reclaimed by any userspace action.

### The workaround had become actively harmful

The broker's residency ceiling was fail-closed: entries were reused only on an
**exact** size match, and `total_bytes` was never decremented, so it was a
monotonic high-water mark. Workloads allocating many *distinct* sizes therefore
exhausted the 4 GiB default ceiling and every subsequent allocation failed with
`ENOSPC`, surfacing in the guest as `VK_ERROR_OUT_OF_HOST_MEMORY`.

This blocked the Vulkan CTS entirely: dEQP aborts a session on `ResourceError`,
so runs died after roughly 150 test cases regardless of guest RAM. With the
broker disabled on a fixed kernel, the same batches complete 500/500 with zero
resource errors.

## What was removed

- `tools/ika-udmabuf-broker` and `tools/tests/test_ika_udmabuf_broker.py`
- `base/cvd/build_external/gfxstream/PATCH.gfxstream.udmabuf-broker.patch`
- `base/cvd/build_external/gfxstream/PATCH.gfxstream.pool-host-visible-udmabufs.patch`
  (exact-size pool and its shared lifetime lease)
- the broker entries in `base/cvd/build_external/gfxstream/gfxstream.MODULE.bazel`
- broker lifecycle, `IKA_UDMABUF_BROKER*` environment handling, and the
  `GFXSTREAM_UDMABUF_BROKER` renderer variable in `tools/ika`
- broker install rules in the RPM, Debian, and Arch packaging

## What was deliberately kept

- `PATCH.gfxstream.linux_udmabuf_creator.patch` and
  `PATCH.gfxstream.memfd_udmabuf_seals.patch` — base Apple Silicon enablement.
  Without these the udmabuf-backed host-visible path does not work at all; see
  [GFXSTREAM-VULKAN.md](../GFXSTREAM-VULKAN.md).
- `tune_udmabuf` in the host-resources service, which raises the `udmabuf`
  kernel module caps that path needs.
- The glibc allocator tunables (`glibc.malloc.arena_max=4`,
  `glibc.malloc.trim_threshold=131072`) applied to Apple Silicon gfxstream
  launches. These address glibc per-thread arena residency, which is unrelated
  to the kernel DMA-BUF defect and is still real.
- `PATCH.gfxstream.force-vulkan-cleanup-on-teardown.patch`, the defensive
  renderer teardown, which is generally correct cleanup rather than a
  workaround.
- The `ika stop` udmabuf baseline/leak diagnostic, which now serves to detect a
  regression or an unfixed kernel instead of narrating expected retention.
