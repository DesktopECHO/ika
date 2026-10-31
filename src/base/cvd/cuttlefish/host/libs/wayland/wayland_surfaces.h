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

#pragma once

#include <stdint.h>

#include <functional>
#include <future>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <unordered_map>
#include <vector>

#include "wayland-server-core.h"

#include "cuttlefish/host/libs/wayland/wayland_server_callbacks.h"

namespace wayland {

class Surface;

class Surfaces {
 public:
  Surfaces();
  virtual ~Surfaces();

  Surfaces(const Surfaces& rhs) = delete;
  Surfaces& operator=(const Surfaces& rhs) = delete;

  Surfaces(Surfaces&& rhs) = delete;
  Surfaces& operator=(Surfaces&& rhs) = delete;

  using FrameCallback = std::function<void(uint32_t /*display_number*/,       //
                                           uint32_t /*frame_width*/,          //
                                           uint32_t /*frame_height*/,         //
                                           uint32_t /*frame_fourcc_format*/,  //
                                           uint32_t /*frame_stride_bytes*/,   //
                                           uint8_t* /*frame_bytes*/)>;
  // The frame id is unique among the frames in flight: a consumer returning
  // kHeld releases the frame with ReleaseDmabufFrame(frame_id) later.
  using DmabufFrameCallback =
      std::function<DmabufFrameResult(uint32_t /*display_number*/,       //
                                      uint32_t /*frame_width*/,          //
                                      uint32_t /*frame_height*/,         //
                                      uint32_t /*frame_fourcc_format*/,  //
                                      int /*dmabuf_fd*/,                 //
                                      uint32_t /*frame_offset*/,         //
                                      uint32_t /*frame_stride_bytes*/,   //
                                      uint32_t /*modifier_hi*/,          //
                                      uint32_t /*modifier_lo*/,          //
                                      uint32_t /*frame_id*/)>;

  void SetFrameCallback(FrameCallback callback);
  void SetDmabufFrameCallback(DmabufFrameCallback callback);

  void SetDisplayEventCallback(DisplayEventCallback event_callback);

  void SetFramesAreRGBA(bool frames_are_rgba);

  // Releases the client's buffer of a held dma-buf frame. Callable from any
  // thread: the release itself happens on the server's thread. Unknown ids
  // (frames released already, or of a surface gone) are ignored.
  void ReleaseDmabufFrame(uint32_t frame_id);

  // Called on the server's thread: held frames are released through this
  // event loop. Without one, dma-buf frames are never held.
  void AttachEventLoop(struct wl_event_loop* loop);
  void DetachEventLoop();

 private:
  friend class Surface;
  void HandleSurfaceFrame(uint32_t display_number,       //
                          uint32_t frame_width,          //
                          uint32_t frame_height,         //
                          uint32_t frame_fourcc_format,  //
                          uint32_t frame_stride_bytes,   //
                          uint8_t* frame_bytes);
  // Hands the frame to the consumer. On kHeld the surface must not release
  // the buffer: it is held here until the consumer releases the frame.
  DmabufFrameResult HandleSurfaceDmabufFrame(
                                Surface* surface,              //
                                struct wl_resource* buffer,    //
                                uint32_t display_number,       //
                                uint32_t frame_width,          //
                                uint32_t frame_height,         //
                                uint32_t frame_fourcc_format,  //
                                int dmabuf_fd,                 //
                                uint32_t frame_offset,         //
                                uint32_t frame_stride_bytes,   //
                                uint32_t modifier_hi,          //
                                uint32_t modifier_lo);

  void HandleSurfaceCreated(uint32_t display_number, uint32_t display_width,
                            uint32_t display_height);

  void HandleSurfaceDestroyed(uint32_t display_number);

  // Releases the buffers still held for the surface (on its destruction).
  void ReleaseHeldDmabufBuffers(Surface* surface);

  // A client buffer kept until the consumer has released its frame. Standard
  // layout: the destroy listener gives the entry back.
  struct HeldDmabufBuffer {
    struct wl_listener buffer_destroyed;
    Surfaces* surfaces;
    Surface* surface;
    uint32_t frame_id;
    struct wl_resource* buffer;
  };

  static void OnHeldBufferDestroyed(struct wl_listener* listener, void* data);
  static int OnReleaseEvent(int fd, uint32_t mask, void* data);

  // Server thread only.
  void HoldDmabufBuffer(Surface* surface, uint32_t frame_id,
                        struct wl_resource* buffer);
  void ReleaseHeldLocked(std::map<uint32_t, HeldDmabufBuffer*>::iterator it,
                         bool send_release);
  void ReleasePendingFrames();

  std::mutex callback_mutex_;
  std::optional<FrameCallback> callback_;
  std::optional<DmabufFrameCallback> dmabuf_callback_;
  std::optional<DisplayEventCallback> event_callback_;
  // If true, report that the received frames are RGBA regardless
  // of the format reported by the wayland client.
  bool frames_are_rgba_ = false;

  // Held buffers, by frame id in the order they were held; server thread only.
  std::map<uint32_t, HeldDmabufBuffer*> held_;
  uint32_t next_frame_id_ = 1;
  bool logged_hold_overflow_ = false;
  struct wl_event_source* release_source_ = nullptr;

  // Frames released by the consumer, waiting for the server thread.
  std::mutex release_mutex_;
  std::vector<uint32_t> released_frames_;
  int release_fd_ = -1;
};

}  // namespace wayland
