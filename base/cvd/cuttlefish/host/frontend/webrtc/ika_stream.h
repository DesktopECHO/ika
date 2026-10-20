/*
 * Copyright (C) 2026 The Android Open Source Project
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

#include <atomic>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "cuttlefish/host/libs/wayland/wayland_server_callbacks.h"

namespace cuttlefish {

struct RawFrameHeader {
  uint32_t magic;
  uint32_t version;
  uint32_t display_number;
  uint32_t width;
  uint32_t height;
  uint32_t fourcc;
  uint32_t stride_bytes;
  uint32_t payload_size;
};

class RawFrameStreamer {
 public:
  explicit RawFrameStreamer(std::string socket_path);
  ~RawFrameStreamer();

  RawFrameStreamer(const RawFrameStreamer&) = delete;
  RawFrameStreamer& operator=(const RawFrameStreamer&) = delete;

  void OnFrame(uint32_t display_number, uint32_t width, uint32_t height,
               uint32_t fourcc, uint32_t stride_bytes, const uint8_t* pixels);
  // Returns kHeld when the frame goes to a client that releases dma-buf
  // frames: the release callback is then called with the frame id once the
  // client has released it, or when the frame is dropped before that.
  DmabufFrameResult OnDmabufFrame(uint32_t display_number, uint32_t width,
                                  uint32_t height, uint32_t fourcc,
                                  int dmabuf_fd, uint32_t offset,
                                  uint32_t stride_bytes, uint32_t modifier_hi,
                                  uint32_t modifier_lo, uint32_t frame_id);
  // Called for each frame OnDmabufFrame() returned kHeld for, from any
  // thread. Set it before the first frame.
  void SetDmabufReleaseCallback(std::function<void(uint32_t)> callback);

 private:
  enum class FrameType {
    kNone,
    kRaw,
    kDmabuf,
  };

  enum class FrameSendResult {
    kSent,
    kUnavailable,
    kFailed,
  };

  struct Frame {
    FrameType type = FrameType::kNone;
    RawFrameHeader header = {};
    std::shared_ptr<const std::vector<uint8_t>> pixels;
    int dmabuf_fd = -1;
    uint32_t offset = 0;
    uint32_t modifier_hi = 0;
    uint32_t modifier_lo = 0;
    // Raw frames written straight into the client's shared memory: the slot
    // holding the pixels, and whether the client thread has taken the frame
    int slot = -1;
    bool slot_sent = false;
    // DMA-BUF frames whose buffer the Wayland server holds until the client
    // releases them: the frame id to release, 0 if the buffer was released
    // at once, and whether the client thread has taken the frame (the hold
    // then belongs to the client, ClientShm::held_dmabufs)
    uint32_t hold_id = 0;
    bool hold_taken = false;
  };

  // The memfd of frame slots shared with the client, unmapped and closed with
  // its last reference: OnFrame() keeps one while it copies a frame into a
  // slot without holding mutex_, so the client thread's unmap waits for it
  struct ShmMapping {
    ShmMapping(int fd, uint8_t* data, size_t size);
    ~ShmMapping();
    ShmMapping(const ShmMapping&) = delete;
    ShmMapping& operator=(const ShmMapping&) = delete;

    const int fd;
    uint8_t* const data;
    const size_t size;
  };

  struct ClientShm {
    std::shared_ptr<ShmMapping> mapping;
    size_t slot_size = 0;
    uint32_t slot_count = 0;
    uint32_t next_slot = 0;
    // Non-zero if the client releases the slots: a slot is only rewritten
    // once the client has released it, tagged with this generation
    uint32_t generation = 0;
    uint32_t busy_slots = 0;  // bitmask
    // Survive CloseClientShm(), they belong to the connection
    bool client_releases_slots = false;
    uint32_t last_generation = 0;
    // The client releases DMA-BUF frames (IKAB): their buffers are held until
    // then, and IKAD carries their ids. The frames it holds, oldest first.
    bool client_releases_dmabufs = false;
    std::vector<uint32_t> held_dmabufs;
    // The display the client shows, from its hello (0 without one)
    uint32_t display_number = 0;
    // The client's window is hidden: frames are kept, not sent (IKAP)
    bool paused = false;
    uint8_t message[16] = {};
    size_t message_size = 0;
  };

  // The frames of one display, and the client showing it. Each display has at
  // most one client; another client of the same display waits for it to leave.
  struct DmabufGeometry {
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t fourcc = 0;
    uint32_t stride_bytes = 0;
    uint32_t offset = 0;
    uint32_t modifier_hi = 0;
    uint32_t modifier_lo = 0;

    bool operator==(const DmabufGeometry& other) const {
      return width == other.width && height == other.height &&
             fourcc == other.fourcc && stride_bytes == other.stride_bytes &&
             offset == other.offset && modifier_hi == other.modifier_hi &&
             modifier_lo == other.modifier_lo;
    }
  };

  struct DisplayStream {
    int client_fd = -1;
    // The client thread's eventfd, written when generation changes
    int wake_fd = -1;
    uint64_t generation = 0;
    bool suppress_next_raw = false;
    Frame latest_frame;
    ClientShm shm;
    // The last DMA-BUF geometry logged for this display, to log it once.
    DmabufGeometry dmabuf_geometry;
  };

  struct ClientThread {
    std::thread thread;
    std::shared_ptr<std::atomic<bool>> done;
  };

  void ServerLoop();
  void ClientLoop(int client_fd);
  void StreamToClient(int client_fd, DisplayStream& display);
  bool SendAll(int fd, const void* data, size_t size);
  bool SendDmabufFrame(int fd, const Frame& frame, bool with_frame_id);
  bool SendRawFrame(int fd, const Frame& frame, DisplayStream& display);
  FrameSendResult SendShmInit(int fd, DisplayStream& display,
                              size_t payload_size);
  FrameSendResult SendShmFrame(int fd, const Frame& frame,
                               DisplayStream& display);
  bool SendShmNotify(int fd, const Frame& frame, uint32_t slot_index);
  bool ReadClientMessages(int fd, ClientShm& shm);
  bool AcquireShmSlot(int fd, ClientShm& shm, uint32_t* slot_index);
  void CloseClientShm(ClientShm& shm) const;
  DisplayStream& GetDisplayLocked(uint32_t display_number);
  void EndClientLocked(DisplayStream& display);
  bool ReserveSlotLocked(DisplayStream& display, uint32_t payload_size,
                         uint32_t* slot_index);
  void DetachLatestFrameFromShmLocked(DisplayStream& display);
  void ReplaceLatestFrameLocked(DisplayStream& display, Frame frame);
  void FrameChangedLocked(DisplayStream& display);
  bool WaitForClientOrFrame(int client_fd, int wake_fd);
  Frame CopyLatestFrameLocked(DisplayStream& display);
  void CloseFrameFd(Frame& frame) const;
  void ReleaseDmabufHold(uint32_t hold_id);
  // The hold of a frame never taken by a client, if any, ends
  void ReleaseLatestHoldLocked(DisplayStream& display);
  std::shared_ptr<std::vector<uint8_t>> AcquireRawBufferLocked(size_t size);

  std::string socket_path_;
  std::function<void(uint32_t)> dmabuf_release_callback_;
  std::thread server_thread_;
  int server_fd_ = -1;
  // Only used by the server thread
  std::vector<ClientThread> client_threads_;

  std::mutex mutex_;
  std::condition_variable frame_cv_;
  bool stopped_ = false;
  std::set<int> client_fds_;
  // By display number, never removed. A display's client slots: only its
  // client thread maps, unmaps and reconfigures them, under mutex_; OnFrame()
  // reserves a free slot under mutex_, copies the frame into it without the
  // lock, and publishes it under mutex_ again.
  std::map<uint32_t, std::unique_ptr<DisplayStream>> displays_;
  std::vector<std::shared_ptr<std::vector<uint8_t>>> raw_buffers_;
  size_t next_raw_buffer_ = 0;
};

}  // namespace cuttlefish
