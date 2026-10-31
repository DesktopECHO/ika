/*
 * Copyright (C) 2020 The Android Open Source Project
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

#include "cuttlefish/host/libs/wayland/wayland_surfaces.h"

#include <errno.h>
#include <stdint.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include <iterator>
#include <mutex>
#include <utility>
#include <vector>

#include "absl/log/log.h"
#include "drm/drm_fourcc.h"
#include "wayland-server-protocol.h"

#include "cuttlefish/host/libs/wayland/wayland_surface.h"

namespace wayland {
namespace {

// How many dma-buf buffers of one surface may be held at once. The guest's
// swapchain has three buffers, and the console legitimately holds the frame
// it displays, the next one, and briefly the one being attached in between;
// holding a fourth would mean the consumer leaks them.
constexpr size_t kMaxHeldDmabufBuffers = 3;

}  // namespace

Surfaces::Surfaces() = default;

Surfaces::~Surfaces() {
  DetachEventLoop();
  // The display is gone with every client buffer, and the destroy listeners
  // have dropped the entries. Anything left belongs to no resource anymore.
  for (auto& [frame_id, held] : held_) {
    delete held;
  }
  held_.clear();
}

void Surfaces::SetFrameCallback(FrameCallback callback) {
  std::unique_lock<std::mutex> lock(callback_mutex_);
  callback_.emplace(std::move(callback));
}

void Surfaces::SetDmabufFrameCallback(DmabufFrameCallback callback) {
  std::unique_lock<std::mutex> lock(callback_mutex_);
  dmabuf_callback_.emplace(std::move(callback));
}

void Surfaces::SetDisplayEventCallback(DisplayEventCallback callback) {
  std::unique_lock<std::mutex> lock(callback_mutex_);
  event_callback_.emplace(std::move(callback));
}

void Surfaces::SetFramesAreRGBA(bool frames_are_rgba) {
  frames_are_rgba_ = frames_are_rgba;
}

void Surfaces::HandleSurfaceFrame(uint32_t display_number, uint32_t frame_width,
                                  uint32_t frame_height,
                                  uint32_t frame_fourcc_format,
                                  uint32_t frame_stride_bytes,
                                  uint8_t* frame_bytes) {
  if (frames_are_rgba_) {
    frame_fourcc_format = DRM_FORMAT_ABGR8888;
  }

  std::unique_lock<std::mutex> lock(callback_mutex_);

  if (callback_) {
    (callback_.value())(display_number, frame_width, frame_height,
                        frame_fourcc_format, frame_stride_bytes, frame_bytes);
  }
}

DmabufFrameResult Surfaces::HandleSurfaceDmabufFrame(
    Surface* surface, struct wl_resource* buffer, uint32_t display_number,
    uint32_t frame_width,
    uint32_t frame_height, uint32_t frame_fourcc_format, int dmabuf_fd,
    uint32_t frame_offset, uint32_t frame_stride_bytes, uint32_t modifier_hi,
    uint32_t modifier_lo) {
  // Frame ids are never 0, so that consumers can use 0 for "not held".
  const uint32_t frame_id = next_frame_id_++;
  if (next_frame_id_ == 0) {
    next_frame_id_ = 1;
  }

  DmabufFrameResult result = DmabufFrameResult::kNotDelivered;
  {
    std::unique_lock<std::mutex> lock(callback_mutex_);
    if (dmabuf_callback_) {
      result = (dmabuf_callback_.value())(
          display_number, frame_width, frame_height, frame_fourcc_format,
          dmabuf_fd, frame_offset, frame_stride_bytes, modifier_hi,
          modifier_lo, frame_id);
    }
  }
  if (result == DmabufFrameResult::kHeld) {
    if (release_source_ == nullptr) {
      // No way to release it later: the consumer's release will be ignored.
      LOG_FIRST_N(WARNING, 1)
          << "Dma-buf frame held without an event loop: released at once.";
      return DmabufFrameResult::kDelivered;
    }
    HoldDmabufBuffer(surface, frame_id, buffer);
  }
  return result;
}

void Surfaces::HandleSurfaceCreated(uint32_t display_number,
                                    uint32_t display_width,
                                    uint32_t display_height) {
  const DisplayEvent event{DisplayCreatedEvent{
      .display_number = display_number,
      .display_width = display_width,
      .display_height = display_height,
  }};

  std::unique_lock<std::mutex> lock(callback_mutex_);
  if (event_callback_) {
    (event_callback_.value())(event);
  }
}

void Surfaces::HandleSurfaceDestroyed(uint32_t display_number) {
  const DisplayEvent event{DisplayDestroyedEvent{
      .display_number = display_number,
  }};

  std::unique_lock<std::mutex> lock(callback_mutex_);
  if (event_callback_) {
    (event_callback_.value())(event);
  }
}

void Surfaces::AttachEventLoop(struct wl_event_loop* loop) {
  DetachEventLoop();
  release_fd_ = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  if (release_fd_ < 0) {
    PLOG(ERROR) << "Failed to create the dma-buf release eventfd";
    return;
  }
  release_source_ = wl_event_loop_add_fd(loop, release_fd_, WL_EVENT_READABLE,
                                         OnReleaseEvent, this);
  if (release_source_ == nullptr) {
    LOG(ERROR) << "Failed to watch the dma-buf release eventfd";
    close(release_fd_);
    release_fd_ = -1;
  }
}

void Surfaces::DetachEventLoop() {
  if (release_source_ != nullptr) {
    wl_event_source_remove(release_source_);
    release_source_ = nullptr;
  }
  if (release_fd_ >= 0) {
    close(release_fd_);
    release_fd_ = -1;
  }
}

void Surfaces::ReleaseDmabufFrame(uint32_t frame_id) {
  std::lock_guard<std::mutex> lock(release_mutex_);
  if (release_fd_ < 0) {
    return;
  }
  released_frames_.push_back(frame_id);
  const uint64_t one = 1;
  if (write(release_fd_, &one, sizeof(one)) != sizeof(one)) {
    PLOG(WARNING) << "Failed to signal a dma-buf frame release";
  }
}

int Surfaces::OnReleaseEvent(int fd, uint32_t, void* data) {
  uint64_t count = 0;
  while (read(fd, &count, sizeof(count)) < 0 && errno == EINTR) {
  }
  static_cast<Surfaces*>(data)->ReleasePendingFrames();
  return 0;
}

void Surfaces::ReleasePendingFrames() {
  std::vector<uint32_t> released;
  {
    std::lock_guard<std::mutex> lock(release_mutex_);
    released.swap(released_frames_);
  }
  for (uint32_t frame_id : released) {
    auto it = held_.find(frame_id);
    if (it == held_.end()) {
      VLOG(1) << "Dma-buf frame " << frame_id << " released, not held";
      continue;
    }
    VLOG(1) << "Dma-buf frame " << frame_id << " released by the consumer";
    ReleaseHeldLocked(it, /*send_release=*/true);
  }
}

void Surfaces::OnHeldBufferDestroyed(struct wl_listener* listener, void*) {
  HeldDmabufBuffer* held = nullptr;
  held = wl_container_of(listener, held, buffer_destroyed);
  Surfaces* surfaces = held->surfaces;
  VLOG(1) << "Dma-buf frame " << held->frame_id
          << " released: its buffer is destroyed";
  auto it = surfaces->held_.find(held->frame_id);
  if (it != surfaces->held_.end()) {
    surfaces->ReleaseHeldLocked(it, /*send_release=*/false);
  }
}

void Surfaces::HoldDmabufBuffer(Surface* surface, uint32_t frame_id,
                                struct wl_resource* buffer) {
  size_t held_of_surface = 0;
  std::map<uint32_t, HeldDmabufBuffer*>::iterator oldest = held_.end();
  for (auto it = held_.begin(); it != held_.end();) {
    HeldDmabufBuffer* held = it->second;
    if (held->buffer == buffer) {
      // The client attached the buffer again before its release: it reuses
      // it anyway, so the earlier frame's hold is void. One release goes to
      // the client, with this frame's.
      VLOG(1) << "Dma-buf frame " << held->frame_id
              << " superseded: its buffer is attached again";
      auto next = std::next(it);
      ReleaseHeldLocked(it, /*send_release=*/false);
      it = next;
      continue;
    }
    if (held->surface == surface) {
      ++held_of_surface;
      if (oldest == held_.end()) {
        oldest = it;
      }
    }
    ++it;
  }

  if (held_of_surface >= kMaxHeldDmabufBuffers && oldest != held_.end()) {
    if (!logged_hold_overflow_) {
      LOG(WARNING) << "The consumer holds " << held_of_surface
                   << " dma-buf frames of one display: releasing the oldest "
                      "(frame "
                   << oldest->second->frame_id << ") anyway.";
      logged_hold_overflow_ = true;
    }
    ReleaseHeldLocked(oldest, /*send_release=*/true);
  }

  HeldDmabufBuffer* held = new HeldDmabufBuffer{
      .buffer_destroyed = {},
      .surfaces = this,
      .surface = surface,
      .frame_id = frame_id,
      .buffer = buffer,
  };
  held->buffer_destroyed.notify = OnHeldBufferDestroyed;
  wl_resource_add_destroy_listener(buffer, &held->buffer_destroyed);
  held_[frame_id] = held;
  VLOG(1) << "Dma-buf frame " << frame_id << " held, buffer " << buffer;
}

void Surfaces::ReleaseHeldLocked(
    std::map<uint32_t, HeldDmabufBuffer*>::iterator it, bool send_release) {
  HeldDmabufBuffer* held = it->second;
  held_.erase(it);
  wl_list_remove(&held->buffer_destroyed.link);
  if (send_release) {
    wl_buffer_send_release(held->buffer);
    wl_client_flush(wl_resource_get_client(held->buffer));
  }
  delete held;
}

void Surfaces::ReleaseHeldDmabufBuffers(Surface* surface) {
  for (auto it = held_.begin(); it != held_.end();) {
    if (it->second->surface != surface) {
      ++it;
      continue;
    }
    VLOG(1) << "Dma-buf frame " << it->second->frame_id
            << " released: its surface is destroyed";
    auto next = std::next(it);
    ReleaseHeldLocked(it, /*send_release=*/true);
    it = next;
  }
}

}  // namespace wayland
