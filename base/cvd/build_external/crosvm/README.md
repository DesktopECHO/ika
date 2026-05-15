# crosvm build patches

Patches applied to upstream [crosvm](https://chromium.googlesource.com/crosvm/crosvm) (pinned to `CROSVM_REV` in [`crosvm.MODULE.bazel`](crosvm.MODULE.bazel)) and to vendored Cargo dependencies pulled in by `crosvm_bin`. Wiring lives in `crosvm.MODULE.bazel`; each `crosvm_bin.annotation(crate = ..., patches = [...])` lists the patches that apply to a given crate, and the bottom `git_repository` block lists patches applied to the source tree itself.

## Patches

### Behavioral / feature patches

#### `PATCH.crosvm-disable-gfxstream-vulkan-apple-16k.patch`
- **Targets:** `crosvm_bin` (binary). File: `src/crosvm/gpu_config.rs`.
- **What it does:** Auto-detects an Apple Silicon Linux host (aarch64 + `pagesize() > 4096` + `/proc/device-tree/compatible` containing `apple,`) and, on such hosts, clears the `gfxstream-vulkan` bit from `GpuParameters::capset_mask` and forces `use_vulkan = false`. The `gfxstream-gles` capset is left intact.
- **Why:** On Asahi (16 KiB-page aarch64), the gfxstream-vulkan blob path hits a chain of alignment and `VmMemorySource` incompatibilities (`VmMemorySource::Vulkan is not compatible with fixed mapping into prepared memory region`, plus host KVM `EINVAL`s on `KVM_SET_USER_MEMORY_REGION`). Disabling the Vulkan capset and falling back to GLES sidesteps that path entirely until the upstream fixes (`b/323368701`) land.

#### `PATCH.crosvm-composite-duplicate-components.patch`
- **Targets:** `crosvm_bin` and the source `git_repository`. File: `disk/src/composite.rs`.
- **What it does:** Introduces `OpenComponentDiskKey` (path + open-mode tuple) and a `HashMap`-backed cache so a composite disk that references the same backing component multiple times only opens the underlying file once, sharing the open handle across `ComponentDiskPart` entries.
- **Why:** Some Cuttlefish composite layouts reference the same component disk from more than one slot. Without dedup, each reference re-opens the file with conflicting locks/flags and `composite::open` fails.

#### `PATCH.crosvm-resize-display.patch`
- **Targets:** `crosvm_bin` and the source `git_repository`. File: `devices/src/virtio/gpu/virtio_gpu.rs`.
- **What it does:** Adds `VirtioGpu::resize_display(display_id, DisplayParameters)` that updates an existing scanout's `width`, `height`, and stored `display_params`, then flips `scanouts_updated` so the GPU thread re-syncs.
- **Why:** Upstream crosvm only supports add/remove of scanouts at runtime. Cuttlefish's `ika` launcher needs in-place resize so the host window can be resized without tearing down the display.

#### `PATCH.crosvm-resize-display-devices.patch`
- **Targets:** `devices` crate (vendored via cargo). File: `src/virtio/gpu/virtio_gpu.rs`.
- **What it does:** Same code change as `PATCH.crosvm-resize-display.patch`, but rebased onto the path layout used when `devices` is consumed as a published crate (no `devices/` prefix).
- **Why:** Bazel rebuilds both the binary (from the source git tree) and the `devices` crate (from cargo), so the same change has to be supplied twice with different prefixes.

#### `PATCH.crosvm-resize-display-vm-control.patch`
- **Targets:** `vm_control` crate. Files: `src/client.rs`, `src/gpu.rs`.
- **What it does:** Adds a `ResizeDisplay { display_id, display }` variant to `GpuControlCommand` and re-exports `do_gpu_display_resize` from `client.rs`. Pair with the `resize_display` patches so the control-socket protocol exposes the new operation end-to-end.
- **Why:** Without this, the `resize_display` capability added on the device side has no client-facing command.

### Upstream-sync patches (large)

#### `PATCH.mesa3d_util-upstream-main-20260520.patch`
- **Targets:** `mesa3d_util` crate.
- **What it does:** Adds new modules (notably `atomic_memory_sentinel.rs`) and other API surface required by the newer `rutabaga_gfx`. Effectively fast-forwards the pinned `mesa3d_util` crate to upstream `main` as of 2026-05-20.
- **Why:** The `rutabaga_gfx` upstream-sync patch below depends on `AtomicMemorySentinel` and other helpers that don't exist in the crate version Cargo resolves to. Without this patch, that one fails to compile.

#### `PATCH.rutabaga_gfx-upstream-main-20260520.patch`
- **Targets:** `rutabaga_gfx` crate.
- **What it does:** Fast-forwards `rutabaga_gfx` to upstream `main` as of 2026-05-20 — adds `cross_domain/atomic_memory_sentinel_manager.rs`, refreshes `cross_domain/{protocol,mod}.rs`, `rutabaga_core.rs`, `rutabaga_gralloc/gralloc.rs`, `rutabaga_utils.rs`, `lib.rs`.
- **Why:** Picks up bug fixes and API additions needed by both crosvm and gfxstream that haven't landed in a published crate release.

### Build-system patches (no runtime effect)

#### `PATCH.rutabaga_gfx_build_rs.patch`
- **Targets:** `rutabaga_gfx` crate. File: `build.rs`.
- **What it does:** Replaces the `pkg-config`-based discovery of `gbm` / `virglrenderer` with logic that works inside the Bazel sandbox (no `pkg-config` available; libs are vendored).
- **Why:** Without it, `cargo build` of `rutabaga_gfx` aborts during the build script because `pkg-config` can't find the host libraries (sandbox isolates them).

#### `PATCH.minijail-sys_build_rs.patch`
- **Targets:** `minijail-sys` crate. File: `build.rs`.
- **What it does:** Adds `find_minijail_root()` which scans `external/*/third_party/minijail` for `Makefile` + `libminijail.h` instead of hardcoding the canonical repo name.
- **Why:** Bazel renames external repos based on the rule version (e.g. `+_repo_rules6+crosvm`, `+_repo_rules2+crosvm`). Hardcoding any one of those breaks the build whenever Bazel bumps the rule version.

#### `PATCH.minijail-sys_common_mk.patch`
- **Targets:** Source `git_repository` (under `third_party/minijail/`). File: `common.mk`.
- **What it does:** Adds `-Wno-unused-command-line-argument` to `COMMON_CFLAGS`.
- **Why:** Bazel-driven clang invocations sometimes pass flags ignored by `cc1` (e.g. linker-only options to a compile step). With `-Werror` in `COMMON_CFLAGS`, the otherwise-harmless warning turns into a build failure.

#### `PATCH.proto_build_tools.patch`
- **Targets:** `proto_build_tools` crate. File: `src/lib.rs`.
- **What it does:** Drops the `#[path = "<out_dir>/<file>.rs"]` directive that the generator was emitting alongside each `pub mod ...;` declaration.
- **Why:** `out_dir` resolves to a temporary path inside the Bazel sandbox at codegen time. If that path is baked into the generated source, the next consumer of the crate fails to find it (the sandbox is gone). Removing the `#[path]` lets the standard `pub mod` lookup find the generated file via the build script's `OUT_DIR` env at compile time.

## How they're wired

See `crosvm.MODULE.bazel`. The relevant blocks:

| Target | Patches |
|---|---|
| `crosvm_bin.annotation(crate = "crosvm")` | `crosvm-composite-duplicate-components`, `crosvm-resize-display`, `crosvm-disable-gfxstream-vulkan-apple-16k` |
| `crosvm_bin.annotation(crate = "mesa3d_util")` | `mesa3d_util-upstream-main-20260520` |
| `crosvm_bin.annotation(crate = "devices")` | `crosvm-resize-display-devices` |
| `crosvm_bin.annotation(crate = "rutabaga_gfx")` | `rutabaga_gfx_build_rs`, `rutabaga_gfx-upstream-main-20260520` |
| `crosvm_bin.annotation(crate = "minijail-sys")` | `minijail-sys_build_rs` |
| `crosvm_bin.annotation(crate = "proto_build_tools")` | `proto_build_tools` |
| `crosvm_bin.annotation(crate = "vm_control")` | `crosvm-resize-display-vm-control` |
| `git_repository(name = "crosvm")` (source tree) | `crosvm-composite-duplicate-components`, `crosvm-resize-display`, `minijail-sys_common_mk` |
