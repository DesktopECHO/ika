/*
 * Copyright (C) 2019 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "cuttlefish/host/libs/wayland/wayland_surface.h"

#include <stdint.h>

#include <mutex>

#include <drm/drm_fourcc.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-server-protocol.h>

#include "absl/log/check.h"
#include "absl/log/log.h"

#include "cuttlefish/host/libs/wayland/wayland_dmabuf.h"
#include "cuttlefish/host/libs/wayland/wayland_surfaces.h"
#include "cuttlefish/host/libs/wayland/wayland_utils.h"

namespace wayland {
namespace {

uint32_t GetDrmFormat(uint32_t wl_shm_format) {
  switch (wl_shm_format) {
    case WL_SHM_FORMAT_ARGB8888:
      return DRM_FORMAT_ARGB8888;
    case WL_SHM_FORMAT_XRGB8888:
      return DRM_FORMAT_XRGB8888;
    default:
      return wl_shm_format;
  }
}

}  // namespace

Surface::Surface(Surfaces& surfaces) : surfaces_(surfaces) {}

Surface::~Surface() {
  if (state_.virtio_gpu_metadata_.scanout_id.has_value()) {
    const uint32_t display_number = *state_.virtio_gpu_metadata_.scanout_id;
    surfaces_.HandleSurfaceDestroyed(display_number);
  }
}

void Surface::SetRegion(const Region& region) {
  std::unique_lock<std::mutex> lock(state_mutex_);
  state_.region = region;
}

void Surface::Attach(struct wl_resource* buffer) {
  std::unique_lock<std::mutex> lock(state_mutex_);
  state_.pending_buffer = buffer;
}

void Surface::Commit() {
  std::unique_lock<std::mutex> lock(state_mutex_);
  state_.current_buffer = state_.pending_buffer;
  state_.pending_buffer = nullptr;

  if (state_.current_buffer == nullptr) {
    return;
  }

  if (state_.virtio_gpu_metadata_.scanout_id.has_value()) {
    const uint32_t display_number = *state_.virtio_gpu_metadata_.scanout_id;

    struct wl_shm_buffer* shm_buffer = wl_shm_buffer_get(state_.current_buffer);

    uint32_t buffer_w = 0;
    uint32_t buffer_h = 0;
    uint32_t buffer_drm_format = 0;
    uint32_t buffer_stride_bytes = 0;
    uint8_t* buffer_pixels = nullptr;
    void* mapped_dmabuf = nullptr;
    size_t mapped_dmabuf_size = 0;

    if (shm_buffer != nullptr) {
      wl_shm_buffer_begin_access(shm_buffer);
      buffer_w = wl_shm_buffer_get_width(shm_buffer);
      CHECK(buffer_w == state_.region.w);
      buffer_h = wl_shm_buffer_get_height(shm_buffer);
      CHECK(buffer_h == state_.region.h);
      buffer_drm_format = GetDrmFormat(wl_shm_buffer_get_format(shm_buffer));
      buffer_stride_bytes = wl_shm_buffer_get_stride(shm_buffer);
      buffer_pixels =
          reinterpret_cast<uint8_t*>(wl_shm_buffer_get_data(shm_buffer));
    } else {
      CHECK(IsDmabufResource(state_.current_buffer));
      Dmabuf* dmabuf = GetUserData<Dmabuf>(state_.current_buffer);
      buffer_w = dmabuf->width;
      buffer_h = dmabuf->height;
      const DmabufParams& dmabuf_params = dmabuf->params;

      CHECK(dmabuf_params.planes.size() == 1);
      const DmabufPlane& dmabuf_plane = dmabuf_params.planes.begin()->second;

      if (dmabuf_plane.fd.ok()) {
        buffer_drm_format = dmabuf->format;
        buffer_stride_bytes = dmabuf_plane.stride;
        size_t buffer_size = static_cast<size_t>(buffer_h) * buffer_stride_bytes;
        if (buffer_h != 0 && buffer_size / buffer_h != buffer_stride_bytes) {
          LOG(ERROR) << "DMABUF frame size overflow.";
        } else {
          const long page_size = sysconf(_SC_PAGESIZE);
          if (page_size <= 0) {
            PLOG(ERROR) << "Failed to get page size for DMABUF mmap.";
          } else {
            const size_t page_mask = static_cast<size_t>(page_size) - 1;
            const size_t map_offset =
                static_cast<size_t>(dmabuf_plane.offset) & ~page_mask;
            const size_t map_delta =
                static_cast<size_t>(dmabuf_plane.offset) - map_offset;
            mapped_dmabuf_size = buffer_size + map_delta;
            if (mapped_dmabuf_size < buffer_size) {
              LOG(ERROR) << "DMABUF mmap size overflow.";
            } else {
              mapped_dmabuf = mmap(nullptr, mapped_dmabuf_size, PROT_READ,
                                   MAP_SHARED, dmabuf_plane.fd,
                                   static_cast<off_t>(map_offset));
              if (mapped_dmabuf != MAP_FAILED) {
                buffer_pixels =
                    reinterpret_cast<uint8_t*>(mapped_dmabuf) + map_delta;
              } else {
                mapped_dmabuf = nullptr;
                mapped_dmabuf_size = 0;
                PLOG(ERROR) << "Failed to mmap dmabuf.";
              }
            }
          }
        }
      }

    }

    if (!state_.has_notified_surface_create) {
      surfaces_.HandleSurfaceCreated(display_number, buffer_w, buffer_h);
      state_.has_notified_surface_create = true;
    }

    if (buffer_pixels != nullptr) {
      surfaces_.HandleSurfaceFrame(display_number, buffer_w, buffer_h,
                                   buffer_drm_format, buffer_stride_bytes,
                                   buffer_pixels);
    }

    if (shm_buffer != nullptr) {
      wl_shm_buffer_end_access(shm_buffer);
    } else {
      if (mapped_dmabuf != nullptr) {
        munmap(mapped_dmabuf, mapped_dmabuf_size);
      }
    }
  }

  wl_buffer_send_release(state_.current_buffer);
  wl_client_flush(wl_resource_get_client(state_.current_buffer));

  state_.current_buffer = nullptr;
  state_.current_frame_number++;
}

void Surface::SetVirtioGpuScanoutId(uint32_t scanout_id) {
  std::unique_lock<std::mutex> lock(state_mutex_);
  state_.virtio_gpu_metadata_.scanout_id = scanout_id;
}

}  // namespace wayland
