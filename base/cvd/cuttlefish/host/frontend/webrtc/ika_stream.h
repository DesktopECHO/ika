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

#include <condition_variable>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

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
  bool OnDmabufFrame(uint32_t display_number, uint32_t width, uint32_t height,
                     uint32_t fourcc, int dmabuf_fd, uint32_t offset,
                     uint32_t stride_bytes, uint32_t modifier_hi,
                     uint32_t modifier_lo);

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
  };

  struct ClientShm {
    int fd = -1;
    uint8_t* data = nullptr;
    size_t slot_size = 0;
    uint32_t slot_count = 4;
    uint32_t next_slot = 0;
    // Non-zero if the client releases the slots: a slot is only rewritten
    // once the client has released it, tagged with this generation
    uint32_t generation = 0;
    uint32_t busy_slots = 0;  // bitmask
    // Survive CloseClientShm(), they belong to the connection
    bool client_releases_slots = false;
    uint32_t last_generation = 0;
    uint8_t message[16] = {};
    size_t message_size = 0;
  };

  void ServerLoop();
  void ClientLoop(int client_fd);
  bool SendAll(int fd, const void* data, size_t size);
  bool SendDmabufFrame(int fd, const Frame& frame);
  bool SendRawFrame(int fd, const Frame& frame, ClientShm& shm);
  FrameSendResult SendShmInit(int fd, ClientShm& shm, size_t payload_size);
  FrameSendResult SendShmFrame(int fd, const Frame& frame, ClientShm& shm);
  bool SendShmNotify(int fd, const Frame& frame, uint32_t slot_index);
  bool ReadClientMessages(int fd, ClientShm& shm);
  bool AcquireShmSlot(int fd, ClientShm& shm, uint32_t* slot_index);
  void CloseClientShm(ClientShm& shm) const;
  void EndClientLocked();
  bool WriteSlotFrameLocked(const RawFrameHeader& header,
                            const uint8_t* pixels);
  void DetachLatestFrameFromShmLocked();
  void ReplaceLatestFrameLocked(Frame frame);
  Frame CopyLatestFrameLocked();
  void CloseFrameFd(Frame& frame) const;
  std::shared_ptr<std::vector<uint8_t>> AcquireRawBufferLocked(size_t size);

  std::string socket_path_;
  std::thread server_thread_;
  int server_fd_ = -1;
  int current_client_fd_ = -1;

  std::mutex mutex_;
  std::condition_variable frame_cv_;
  bool stopped_ = false;
  uint64_t generation_ = 0;
  std::optional<uint32_t> suppress_next_raw_display_;
  Frame latest_frame_;
  // The connected client's slots. Only the client thread maps, unmaps and
  // reconfigures them, under mutex_; OnFrame() writes frames into free slots
  // under mutex_ too.
  ClientShm shm_;
  std::vector<std::shared_ptr<std::vector<uint8_t>>> raw_buffers_;
  size_t next_raw_buffer_ = 0;
};

}  // namespace cuttlefish
