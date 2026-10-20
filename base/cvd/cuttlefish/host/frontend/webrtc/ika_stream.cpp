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

#include "cuttlefish/host/frontend/webrtc/ika_stream.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <poll.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <iomanip>
#include <sstream>
#include <utility>

#include "absl/log/log.h"

namespace cuttlefish {
namespace {

constexpr uint32_t kRawFrameMagic = 0x46414b49;  // "IKAF", little-endian.
constexpr uint32_t kRawFrameVersion = 1;
constexpr uint32_t kDmabufFrameMagic = 0x44414b49;  // "IKAD", little-endian.
constexpr uint32_t kDmabufFrameVersion = 1;
// IKAD with a frame id, for clients that release DMA-BUF frames (IKAB)
constexpr uint32_t kDmabufFrameIdVersion = 2;
constexpr uint32_t kShmInitMagic = 0x53414b49;    // "IKAS", little-endian.
constexpr uint32_t kShmNotifyMagic = 0x4e414b49;  // "IKAN", little-endian.
constexpr uint32_t kShmFrameVersion = 1;
// Slots released by the client: IKAS carries a generation, and the client
// sends IKAR once it no longer reads a slot
constexpr uint32_t kShmReleaseVersion = 2;
constexpr uint32_t kClientHelloMagic = 0x48414b49;   // "IKAH", little-endian.
constexpr uint32_t kSlotReleaseMagic = 0x52414b49;   // "IKAR", little-endian.
constexpr uint32_t kClientPauseMagic = 0x50414b49;   // "IKAP", little-endian.
constexpr uint32_t kDmabufReleaseMagic = 0x42414b49;  // "IKAB", little-endian.
// IKAH whose arg0 is a bitmask of what the client releases, sent after the
// version 2 hello (which older servers need exactly as it is)
constexpr uint32_t kClientHelloFlagsVersion = 3;
constexpr uint32_t kHelloReleasesSlots = 1u << 0;
constexpr uint32_t kHelloReleasesDmabufs = 1u << 1;
constexpr int kClientHelloTimeoutMs = 100;
constexpr int kListenBacklog = 4;
constexpr size_t kRawBufferPoolSize = 4;
constexpr int kAcceptPollTimeoutMs = 100;
constexpr int kFrameSendTimeoutMs = 50;
// How often a client thread waiting for a frame reads the client's messages
// when it has no eventfd to be woken through
constexpr int kClientMessagePollMs = 100;
// Frame slots shared with a client: the client holds the frame it shows and
// the next one, the server holds the latest frame not taken yet and the one
// it is copying, and two are slack for the releases on their way back
constexpr uint32_t kSlotCount = 6;

struct DmabufFrameHeader {
  uint32_t magic;
  uint32_t version;
  uint32_t display_number;
  uint32_t width;
  uint32_t height;
  uint32_t fourcc;
  uint32_t offset;
  uint32_t stride_bytes;
  uint32_t modifier_hi;
  uint32_t modifier_lo;
};

// IKAD version 2
struct DmabufFrameIdHeader {
  DmabufFrameHeader frame;
  uint32_t frame_id;
};

struct ShmInitHeader {
  uint32_t magic;
  uint32_t version;
  uint32_t slot_count;
  uint32_t slot_size;
};

struct ShmInitReleaseHeader {
  uint32_t magic;
  uint32_t version;
  uint32_t slot_count;
  uint32_t slot_size;
  uint32_t generation;
};

// Sent by the client: IKAH (arg0 = 1 if it releases slots, arg1 = the display
// it shows) on connection, with IKAH version 3 (arg0 = kHelloReleases* bits)
// if it releases more, then IKAR (arg0 = generation, arg1 = slot index), IKAB
// (arg0 = the id of a DMA-BUF frame it no longer uses) and IKAP (arg0 = 1
// while its window is hidden, 0 when shown again)
struct ClientMessage {
  uint32_t magic;
  uint32_t version;
  uint32_t arg0;
  uint32_t arg1;
};

struct ShmFrameHeader {
  uint32_t magic;
  uint32_t version;
  uint32_t display_number;
  uint32_t width;
  uint32_t height;
  uint32_t fourcc;
  uint32_t stride_bytes;
  uint32_t payload_size;
  uint32_t slot_index;
};

int MemfdCreate(const char* name) {
#ifdef SYS_memfd_create
  return syscall(SYS_memfd_create, name, MFD_CLOEXEC);
#else
  errno = ENOSYS;
  return -1;
#endif
}

using SendDeadline = std::chrono::steady_clock::time_point;

SendDeadline NewSendDeadline() {
  return std::chrono::steady_clock::now() +
         std::chrono::milliseconds(kFrameSendTimeoutMs);
}

int RemainingMillis(SendDeadline deadline) {
  const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
      deadline - std::chrono::steady_clock::now());
  return remaining.count() > 0 ? static_cast<int>(remaining.count()) : 0;
}

bool WaitUntilWritable(int fd, SendDeadline deadline) {
  while (true) {
    const int timeout_ms = RemainingMillis(deadline);
    if (timeout_ms == 0) {
      return false;
    }

    pollfd pfd = {
        .fd = fd,
        .events = POLLOUT,
        .revents = 0,
    };
    const int poll_result = poll(&pfd, 1, timeout_ms);
    if (poll_result < 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    if (poll_result == 0 ||
        (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
      return false;
    }
    if ((pfd.revents & POLLOUT) != 0) {
      return true;
    }
  }
}

bool SendMessageWithDeadline(int fd, msghdr* msg, size_t expected_size) {
  SendDeadline deadline = NewSendDeadline();
  while (true) {
    ssize_t written = sendmsg(fd, msg, MSG_NOSIGNAL | MSG_DONTWAIT);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        if (!WaitUntilWritable(fd, deadline)) {
          return false;
        }
        continue;
      }
      return false;
    }
    return static_cast<size_t>(written) == expected_size;
  }
}

// Wake a client thread waiting in WaitForClientOrFrame()
void SignalWakeFd(int wake_fd) {
  if (wake_fd < 0) {
    return;
  }
  const uint64_t one = 1;
  ssize_t written;
  do {
    written = write(wake_fd, &one, sizeof(one));
  } while (written < 0 && errno == EINTR);
  // EAGAIN: the counter is saturated, the thread is woken anyway
}

}  // namespace

RawFrameStreamer::ShmMapping::ShmMapping(int fd, uint8_t* data, size_t size)
    : fd(fd), data(data), size(size) {}

RawFrameStreamer::ShmMapping::~ShmMapping() {
  if (data != nullptr && size != 0) {
    munmap(data, size);
  }
  if (fd >= 0) {
    close(fd);
  }
}

RawFrameStreamer::RawFrameStreamer(std::string socket_path)
    : socket_path_(std::move(socket_path)) {
  server_thread_ = std::thread([this]() { ServerLoop(); });
}

RawFrameStreamer::~RawFrameStreamer() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopped_ = true;
    frame_cv_.notify_all();
    for (auto& [display_number, display] : displays_) {
      SignalWakeFd(display->wake_fd);
    }
    for (int client_fd : client_fds_) {
      shutdown(client_fd, SHUT_RDWR);
    }
    if (server_fd_ >= 0) {
      shutdown(server_fd_, SHUT_RDWR);
    }
  }

  if (server_thread_.joinable()) {
    server_thread_.join();
  }

  for (auto& [display_number, display] : displays_) {
    CloseFrameFd(display->latest_frame);
  }
  unlink(socket_path_.c_str());
}

void RawFrameStreamer::OnFrame(uint32_t display_number, uint32_t width,
                               uint32_t height, uint32_t fourcc,
                               uint32_t stride_bytes, const uint8_t* pixels) {
  if (width == 0 || height == 0 || stride_bytes == 0 || pixels == nullptr) {
    return;
  }

  const size_t payload_size = static_cast<size_t>(height) * stride_bytes;
  if (payload_size > UINT32_MAX) {
    LOG(WARNING) << "Raw frame too large for stream: " << payload_size;
    return;
  }

  const RawFrameHeader header = {
      .magic = kRawFrameMagic,
      .version = kRawFrameVersion,
      .display_number = display_number,
      .width = width,
      .height = height,
      .fourcc = fourcc,
      .stride_bytes = stride_bytes,
      .payload_size = static_cast<uint32_t>(payload_size),
  };

  // Straight into a free slot of the client's shared memory when it has one:
  // reserve the slot under the lock, copy without it, publish under it again
  std::shared_ptr<std::vector<uint8_t>> payload;
  std::shared_ptr<ShmMapping> mapping;
  uint8_t* slot_data = nullptr;
  uint32_t slot_index = 0;
  DisplayStream* display;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    display = &GetDisplayLocked(display_number);
    if (display->suppress_next_raw) {
      display->suppress_next_raw = false;
      return;
    }
    if (ReserveSlotLocked(*display, header.payload_size, &slot_index)) {
      mapping = display->shm.mapping;
      slot_data = mapping->data +
                  static_cast<size_t>(slot_index) * display->shm.slot_size;
    } else {
      payload = AcquireRawBufferLocked(payload_size);
    }
  }

  Frame frame;
  frame.type = FrameType::kRaw;
  frame.header = header;

  if (mapping) {
    memcpy(slot_data, pixels, payload_size);
    frame.slot = static_cast<int>(slot_index);

    std::lock_guard<std::mutex> lock(mutex_);
    // The slots were unmapped meanwhile (client gone, or slots remade): the
    // reservation went with them, the frame is dropped
    if (display->shm.mapping != mapping) {
      return;
    }
    ReplaceLatestFrameLocked(*display, std::move(frame));
    FrameChangedLocked(*display);
    return;
  }

  payload->assign(pixels, pixels + payload_size);
  frame.pixels = std::move(payload);

  std::lock_guard<std::mutex> lock(mutex_);
  ReplaceLatestFrameLocked(*display, std::move(frame));
  FrameChangedLocked(*display);
}

RawFrameStreamer::DisplayStream& RawFrameStreamer::GetDisplayLocked(
    uint32_t display_number) {
  auto& display = displays_[display_number];
  if (!display) {
    display = std::make_unique<DisplayStream>();
  }
  return *display;
}

// Reserve a free slot of the client's shared memory for a frame, so that
// OnFrame() copies it there and the client thread only tells the client which
// slot holds it. Takes a client that releases the slots, with slots big enough
// for the frame. The slot is busy from now on: the client thread cannot hand
// it out, and it is freed when the frame published in it is replaced unsent,
// or released by the client. The latest frame's own slot stays busy even when
// the client thread hasn't taken it yet: it may take it during the copy.
bool RawFrameStreamer::ReserveSlotLocked(DisplayStream& display,
                                         uint32_t payload_size,
                                         uint32_t* slot_index) {
  ClientShm& shm = display.shm;
  if (!shm.mapping || !shm.generation || payload_size > shm.slot_size) {
    return false;
  }

  for (uint32_t i = 0; i < shm.slot_count; ++i) {
    const uint32_t index = (shm.next_slot + i) % shm.slot_count;
    if ((shm.busy_slots & (1u << index)) != 0) {
      continue;
    }
    shm.busy_slots |= 1u << index;
    shm.next_slot = index + 1;
    *slot_index = index;
    return true;
  }
  return false;
}

// Copy the latest frame out of the shared memory before it is unmapped, so
// that the next client still gets it
void RawFrameStreamer::DetachLatestFrameFromShmLocked(DisplayStream& display) {
  Frame& latest_frame = display.latest_frame;
  if (latest_frame.slot < 0) {
    return;
  }
  const ClientShm& shm = display.shm;
  if (shm.mapping) {
    const size_t payload_size = latest_frame.header.payload_size;
    const uint8_t* slot = shm.mapping->data +
                          static_cast<size_t>(latest_frame.slot) * shm.slot_size;
    auto payload = AcquireRawBufferLocked(payload_size);
    payload->assign(slot, slot + payload_size);
    latest_frame.pixels = std::move(payload);
  } else {
    latest_frame.type = FrameType::kNone;
  }
  latest_frame.slot = -1;
  latest_frame.slot_sent = false;
}

void RawFrameStreamer::ReplaceLatestFrameLocked(DisplayStream& display,
                                                Frame frame) {
  Frame& latest_frame = display.latest_frame;
  // A slot never sent to the client is free again
  if (latest_frame.slot >= 0 && !latest_frame.slot_sent &&
      latest_frame.slot != frame.slot) {
    display.shm.busy_slots &= ~(1u << latest_frame.slot);
  }
  // So is the buffer of a DMA-BUF frame never sent
  ReleaseLatestHoldLocked(display);
  CloseFrameFd(latest_frame);
  latest_frame = std::move(frame);
}

// A new latest frame: wake the display's client thread
void RawFrameStreamer::FrameChangedLocked(DisplayStream& display) {
  ++display.generation;
  SignalWakeFd(display.wake_fd);
}

void RawFrameStreamer::SetDmabufReleaseCallback(
    std::function<void(uint32_t)> callback) {
  dmabuf_release_callback_ = std::move(callback);
}

void RawFrameStreamer::ReleaseDmabufHold(uint32_t hold_id) {
  if (hold_id != 0 && dmabuf_release_callback_) {
    dmabuf_release_callback_(hold_id);
  }
}

void RawFrameStreamer::ReleaseLatestHoldLocked(DisplayStream& display) {
  Frame& latest_frame = display.latest_frame;
  if (latest_frame.hold_id != 0 && !latest_frame.hold_taken) {
    ReleaseDmabufHold(latest_frame.hold_id);
  }
  latest_frame.hold_id = 0;
  latest_frame.hold_taken = false;
}

DmabufFrameResult RawFrameStreamer::OnDmabufFrame(
    uint32_t display_number, uint32_t width, uint32_t height, uint32_t fourcc,
    int dmabuf_fd, uint32_t offset, uint32_t stride_bytes,
    uint32_t modifier_hi, uint32_t modifier_lo, uint32_t frame_id) {
  if (width == 0 || height == 0 || stride_bytes == 0 || dmabuf_fd < 0) {
    return DmabufFrameResult::kNotDelivered;
  }

  int duplicated_fd = fcntl(dmabuf_fd, F_DUPFD_CLOEXEC, 3);
  if (duplicated_fd < 0) {
    PLOG(WARNING) << "Failed to duplicate DMA-BUF fd";
    return DmabufFrameResult::kNotDelivered;
  }

  Frame frame;
  frame.type = FrameType::kDmabuf;
  frame.header = {
      .magic = kDmabufFrameMagic,
      .version = kDmabufFrameVersion,
      .display_number = display_number,
      .width = width,
      .height = height,
      .fourcc = fourcc,
      .stride_bytes = stride_bytes,
      .payload_size = 0,
  };
  frame.dmabuf_fd = duplicated_fd;
  frame.offset = offset;
  frame.modifier_hi = modifier_hi;
  frame.modifier_lo = modifier_lo;

  const DmabufGeometry geometry = {
      .width = width,
      .height = height,
      .fourcc = fourcc,
      .stride_bytes = stride_bytes,
      .offset = offset,
      .modifier_hi = modifier_hi,
      .modifier_lo = modifier_lo,
  };
  bool held = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    DisplayStream& display = GetDisplayLocked(display_number);
    if (!(display.dmabuf_geometry == geometry)) {
      display.dmabuf_geometry = geometry;
      std::ostringstream description;
      description << width << "x" << height << " "
                  << static_cast<char>(fourcc & 0xff)
                  << static_cast<char>((fourcc >> 8) & 0xff)
                  << static_cast<char>((fourcc >> 16) & 0xff)
                  << static_cast<char>((fourcc >> 24) & 0xff) << " stride "
                  << stride_bytes << " offset " << offset << " modifier 0x"
                  << std::hex << modifier_hi << std::setw(8)
                  << std::setfill('0') << modifier_lo;
      LOG(INFO) << "Display " << display_number
                << " frames arrive as DMA-BUFs: " << description.str();
    }
    // The buffer is held only for a client that will release it: a paused
    // client gets the frame later, if at all, and must not keep the guest
    // from drawing meanwhile
    held = display.client_fd >= 0 && display.shm.client_releases_dmabufs &&
           !display.shm.paused && frame_id != 0;
    if (held) {
      frame.hold_id = frame_id;
    }
    ReplaceLatestFrameLocked(display, std::move(frame));
    display.suppress_next_raw = true;
    FrameChangedLocked(display);
  }
  return held ? DmabufFrameResult::kHeld : DmabufFrameResult::kDelivered;
}

void RawFrameStreamer::ServerLoop() {
  const size_t max_path = sizeof(sockaddr_un::sun_path);
  if (socket_path_.size() >= max_path) {
    LOG(ERROR) << "Raw frame socket path is too long: " << socket_path_;
    return;
  }

  unlink(socket_path_.c_str());

  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
  if (fd < 0) {
    PLOG(ERROR) << "Failed to create raw frame socket";
    return;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) {
      close(fd);
      return;
    }
    server_fd_ = fd;
  }

  sockaddr_un addr = {};
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, socket_path_.c_str(), sizeof(addr.sun_path) - 1);

  if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    PLOG(ERROR) << "Failed to bind raw frame socket: " << socket_path_;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (server_fd_ == fd) {
        server_fd_ = -1;
      }
    }
    close(fd);
    return;
  }

  chmod(socket_path_.c_str(), 0660);

  if (listen(fd, kListenBacklog) != 0) {
    PLOG(ERROR) << "Failed to listen on raw frame socket: " << socket_path_;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (server_fd_ == fd) {
        server_fd_ = -1;
      }
    }
    close(fd);
    return;
  }

  LOG(INFO) << "Raw frame socket listening at " << socket_path_;

  while (true) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopped_) {
        break;
      }
    }

    pollfd pfd = {
        .fd = fd,
        .events = POLLIN,
        .revents = 0,
    };
    const int poll_result = poll(&pfd, 1, kAcceptPollTimeoutMs);
    if (poll_result < 0) {
      if (errno == EINTR) {
        continue;
      }
      PLOG(ERROR) << "Failed to poll raw frame socket";
      break;
    }
    if (poll_result == 0) {
      continue;
    }
    if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!stopped_) {
        LOG(ERROR) << "Raw frame socket is no longer accepting clients";
      }
      break;
    }
    if ((pfd.revents & POLLIN) == 0) {
      continue;
    }

    int client_fd = accept4(fd, nullptr, nullptr, SOCK_CLOEXEC);
    if (client_fd < 0) {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopped_) {
        break;
      }
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
        continue;
      }
      PLOG(ERROR) << "Failed to accept raw frame client";
      continue;
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopped_) {
        close(client_fd);
        break;
      }
      client_fds_.insert(client_fd);
    }

    // Join the threads of the clients gone
    client_threads_.erase(
        std::remove_if(client_threads_.begin(), client_threads_.end(),
                       [](ClientThread& client) {
                         if (!*client.done) {
                           return false;
                         }
                         client.thread.join();
                         return true;
                       }),
        client_threads_.end());

    auto done = std::make_shared<std::atomic<bool>>(false);
    std::thread thread([this, client_fd, done]() {
      ClientLoop(client_fd);
      {
        std::lock_guard<std::mutex> lock(mutex_);
        client_fds_.erase(client_fd);
      }
      close(client_fd);
      *done = true;
    });
    client_threads_.push_back({std::move(thread), std::move(done)});
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (server_fd_ == fd) {
      server_fd_ = -1;
    }
  }
  close(fd);

  for (ClientThread& client : client_threads_) {
    client.thread.join();
  }
  client_threads_.clear();
}

void RawFrameStreamer::ClientLoop(int client_fd) {
  // A client releasing the slots, or showing another display than the main
  // one, says so as soon as it connects
  ClientShm hello;
  pollfd pfd = {
      .fd = client_fd,
      .events = POLLIN,
      .revents = 0,
  };
  if (poll(&pfd, 1, kClientHelloTimeoutMs) > 0 &&
      !ReadClientMessages(client_fd, hello)) {
    return;
  }

  // Written when the display has a new frame, polled along with the client
  // socket; without one the thread polls the socket every kClientMessagePollMs
  int wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  if (wake_fd < 0) {
    PLOG(WARNING) << "Failed to create the raw frame client's eventfd";
  }

  const uint32_t display_number = hello.display_number;
  DisplayStream* display;
  {
    std::unique_lock<std::mutex> lock(mutex_);
    display = &GetDisplayLocked(display_number);
    if (display->client_fd >= 0) {
      LOG(INFO) << "Raw frame client waits for display " << display_number;
    }
    frame_cv_.wait(lock,
                   [&]() { return stopped_ || display->client_fd < 0; });
    if (stopped_) {
      lock.unlock();
      if (wake_fd >= 0) {
        close(wake_fd);
      }
      return;
    }
    display->client_fd = client_fd;
    display->wake_fd = wake_fd;
    display->shm = hello;
  }

  LOG(INFO) << "Raw frame client connected to display " << display_number;
  StreamToClient(client_fd, *display);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    EndClientLocked(*display);
    display->client_fd = -1;
    display->wake_fd = -1;
  }
  if (wake_fd >= 0) {
    close(wake_fd);
  }
  // Let a client waiting for the display in
  frame_cv_.notify_all();
  LOG(INFO) << "Raw frame client of display " << display_number
            << " disconnected";
}

// Wait until the client sent a message, or the display has a new frame
// (wake_fd was written). Return false if the client is gone.
bool RawFrameStreamer::WaitForClientOrFrame(int client_fd, int wake_fd) {
  pollfd pfds[2] = {
      {
          .fd = client_fd,
          .events = POLLIN,
          .revents = 0,
      },
      {
          .fd = wake_fd,
          .events = POLLIN,
          .revents = 0,
      },
  };
  const nfds_t count = wake_fd >= 0 ? 2 : 1;
  const int timeout_ms = wake_fd >= 0 ? -1 : kClientMessagePollMs;
  while (true) {
    const int poll_result = poll(pfds, count, timeout_ms);
    if (poll_result < 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    break;
  }
  if ((pfds[0].revents & POLLNVAL) != 0) {
    return false;
  }
  if (count == 2 && (pfds[1].revents & POLLIN) != 0) {
    uint64_t wakes;
    ssize_t r;
    do {
      r = read(wake_fd, &wakes, sizeof(wakes));
    } while (r < 0 && errno == EINTR);
  }
  // A hung-up or failed socket is found by the read that follows
  return true;
}

void RawFrameStreamer::StreamToClient(int client_fd, DisplayStream& display) {
  uint64_t sent_generation = 0;
  while (true) {
    // The client's releases, pause and resume are read as soon as they
    // arrive: a paused client gets the latest frame once it is shown again
    if (!ReadClientMessages(client_fd, display.shm)) {
      return;
    }
    Frame frame;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopped_) {
        return;
      }
      if (display.shm.paused || display.generation == sent_generation) {
        frame.type = FrameType::kNone;
      } else {
        sent_generation = display.generation;
        frame = CopyLatestFrameLocked(display);
      }
    }
    if (frame.type == FrameType::kNone) {
      if (!WaitForClientOrFrame(client_fd, display.wake_fd)) {
        return;
      }
      continue;
    }

    if (frame.type == FrameType::kNone) {
      continue;
    }

    bool ok = false;
    if (frame.type == FrameType::kRaw && frame.slot >= 0) {
      ok = SendShmNotify(client_fd, frame, frame.slot);
    } else if (frame.type == FrameType::kRaw) {
      ok = SendRawFrame(client_fd, frame, display);
    } else {
      ok = SendDmabufFrame(client_fd, frame,
                           display.shm.client_releases_dmabufs);
      if (frame.hold_id != 0) {
        if (ok) {
          // The client holds it until its IKAB, or until it leaves
          std::lock_guard<std::mutex> lock(mutex_);
          display.shm.held_dmabufs.push_back(frame.hold_id);
        } else {
          ReleaseDmabufHold(frame.hold_id);
        }
      }
    }
    CloseFrameFd(frame);
    if (!ok) {
      return;
    }
  }
}

void RawFrameStreamer::EndClientLocked(DisplayStream& display) {
  DetachLatestFrameFromShmLocked(display);
  // The client releases nothing anymore: its buffers go back to the guest,
  // and the next client gets the latest frame without a hold
  for (uint32_t hold_id : display.shm.held_dmabufs) {
    ReleaseDmabufHold(hold_id);
  }
  display.shm.held_dmabufs.clear();
  ReleaseLatestHoldLocked(display);
  CloseClientShm(display.shm);
}

bool RawFrameStreamer::SendAll(int fd, const void* data, size_t size) {
  const uint8_t* ptr = reinterpret_cast<const uint8_t*>(data);
  SendDeadline deadline = NewSendDeadline();
  while (size > 0) {
    ssize_t written = send(fd, ptr, size, MSG_NOSIGNAL | MSG_DONTWAIT);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        if (!WaitUntilWritable(fd, deadline)) {
          return false;
        }
        continue;
      }
      return false;
    }
    if (written == 0) {
      return false;
    }
    ptr += written;
    size -= written;
  }
  return true;
}

bool RawFrameStreamer::SendRawFrame(int fd, const Frame& frame,
                                    DisplayStream& display) {
  if (!frame.pixels || frame.pixels->empty()) {
    return false;
  }

  const FrameSendResult shm_result = SendShmFrame(fd, frame, display);
  if (shm_result == FrameSendResult::kSent) {
    return true;
  }
  if (shm_result == FrameSendResult::kFailed) {
    return false;
  }

  return SendAll(fd, &frame.header, sizeof(frame.header)) &&
         SendAll(fd, frame.pixels->data(), frame.pixels->size());
}

RawFrameStreamer::FrameSendResult RawFrameStreamer::SendShmInit(
    int fd, DisplayStream& display, size_t payload_size) {
  ClientShm& shm = display.shm;
  const size_t slot_size = std::max<size_t>(payload_size, 1);
  if (slot_size > UINT32_MAX) {
    return FrameSendResult::kUnavailable;
  }
  const size_t mapping_size = slot_size * kSlotCount;
  if (mapping_size / kSlotCount != slot_size) {
    return FrameSendResult::kUnavailable;
  }

  int shm_fd = MemfdCreate("ika-raw-frame-slots");
  if (shm_fd < 0) {
    PLOG(WARNING) << "Failed to create raw frame shared memory";
    return FrameSendResult::kUnavailable;
  }

  if (ftruncate(shm_fd, mapping_size) != 0) {
    PLOG(WARNING) << "Failed to size raw frame shared memory";
    close(shm_fd);
    return FrameSendResult::kUnavailable;
  }

  void* mapping = mmap(nullptr, mapping_size, PROT_READ | PROT_WRITE,
                       MAP_SHARED, shm_fd, 0);
  if (mapping == MAP_FAILED) {
    PLOG(WARNING) << "Failed to map raw frame shared memory";
    close(shm_fd);
    return FrameSendResult::kUnavailable;
  }

  const uint32_t generation =
      shm.client_releases_slots ? shm.last_generation + 1 : 0;
  ShmInitReleaseHeader header = {
      .magic = kShmInitMagic,
      .version = generation ? kShmReleaseVersion : kShmFrameVersion,
      .slot_count = kSlotCount,
      .slot_size = static_cast<uint32_t>(slot_size),
      .generation = generation,
  };
  const size_t header_size =
      generation ? sizeof(ShmInitReleaseHeader) : sizeof(ShmInitHeader);

  iovec iov = {};
  iov.iov_base = &header;
  iov.iov_len = header_size;

  alignas(struct cmsghdr) char control[CMSG_SPACE(sizeof(int))] = {};
  msghdr msg = {};
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = control;
  msg.msg_controllen = sizeof(control);

  cmsghdr* cmsg = CMSG_FIRSTHDR(&msg);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(sizeof(int));
  memcpy(CMSG_DATA(cmsg), &shm_fd, sizeof(int));

  bool sent = SendMessageWithDeadline(fd, &msg, header_size);

  if (!sent) {
    munmap(mapping, mapping_size);
    close(shm_fd);
    return FrameSendResult::kFailed;
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    DetachLatestFrameFromShmLocked(display);
    CloseClientShm(shm);
    shm.mapping = std::make_shared<ShmMapping>(
        shm_fd, reinterpret_cast<uint8_t*>(mapping), mapping_size);
    shm.slot_size = slot_size;
    shm.slot_count = kSlotCount;
    shm.next_slot = 0;
    shm.generation = generation;
    shm.busy_slots = 0;
    if (generation) {
      shm.last_generation = generation;
    }
  }

  LOG(INFO) << "Using shared-memory raw frame slots: " << kSlotCount << " x "
            << slot_size << " bytes"
            << (generation ? ", released by the client" : "");
  return FrameSendResult::kSent;
}

RawFrameStreamer::FrameSendResult RawFrameStreamer::SendShmFrame(
    int fd, const Frame& frame, DisplayStream& display) {
  ClientShm& shm = display.shm;
  if (!frame.pixels || frame.pixels->empty() ||
      frame.header.payload_size == 0) {
    return FrameSendResult::kFailed;
  }

  const size_t payload_size = frame.pixels->size();
  if (payload_size > UINT32_MAX) {
    return FrameSendResult::kFailed;
  }
  if (!shm.mapping || payload_size > shm.slot_size) {
    const FrameSendResult init_result =
        SendShmInit(fd, display, payload_size);
    if (init_result == FrameSendResult::kFailed) {
      return init_result;
    }
    // If SHM is now available, continue below and send this frame too. A static
    // desktop may not produce another frame for a long time, so skipping the
    // frame that initialized the slots leaves the client showing zero-filled
    // memory.
    if (init_result == FrameSendResult::kUnavailable) {
      return init_result;
    }
  }
  if (!shm.mapping || payload_size > shm.slot_size || shm.slot_count == 0) {
    return FrameSendResult::kFailed;
  }

  uint32_t slot_index;
  if (!AcquireShmSlot(fd, shm, &slot_index)) {
    return FrameSendResult::kFailed;
  }
  // Only this thread remaps the slots: the mapping outlives the copy
  uint8_t* slot =
      shm.mapping->data + static_cast<size_t>(slot_index) * shm.slot_size;
  memcpy(slot, frame.pixels->data(), payload_size);

  return SendShmNotify(fd, frame, slot_index) ? FrameSendResult::kSent
                                              : FrameSendResult::kFailed;
}

// Tell the client that a slot holds the frame
bool RawFrameStreamer::SendShmNotify(int fd, const Frame& frame,
                                     uint32_t slot_index) {
  ShmFrameHeader header = {
      .magic = kShmNotifyMagic,
      .version = kShmFrameVersion,
      .display_number = frame.header.display_number,
      .width = frame.header.width,
      .height = frame.header.height,
      .fourcc = frame.header.fourcc,
      .stride_bytes = frame.header.stride_bytes,
      .payload_size = frame.header.payload_size,
      .slot_index = slot_index,
  };
  return SendAll(fd, &header, sizeof(header));
}

// Read the pending client messages without blocking. Return false if the
// connection is closed.
bool RawFrameStreamer::ReadClientMessages(int fd, ClientShm& shm) {
  while (true) {
    ssize_t r = recv(fd, shm.message + shm.message_size,
                     sizeof(shm.message) - shm.message_size, MSG_DONTWAIT);
    if (r < 0) {
      if (errno == EINTR) {
        continue;
      }
      return errno == EAGAIN || errno == EWOULDBLOCK;
    }
    if (r == 0) {
      return false;
    }
    shm.message_size += r;
    if (shm.message_size < sizeof(shm.message)) {
      continue;
    }
    shm.message_size = 0;

    ClientMessage message;
    memcpy(&message, shm.message, sizeof(message));
    const bool hello_flags = message.magic == kClientHelloMagic &&
                             message.version == kClientHelloFlagsVersion;
    if (message.version != kShmReleaseVersion && !hello_flags) {
      continue;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (hello_flags) {
      shm.client_releases_slots =
          (message.arg0 & kHelloReleasesSlots) != 0;
      shm.client_releases_dmabufs =
          (message.arg0 & kHelloReleasesDmabufs) != 0;
      shm.display_number = message.arg1;
    } else if (message.magic == kClientHelloMagic) {
      shm.client_releases_slots = message.arg0 == 1;
      shm.display_number = message.arg1;
    } else if (message.magic == kDmabufReleaseMagic) {
      auto& held = shm.held_dmabufs;
      auto it = std::find(held.begin(), held.end(), message.arg0);
      if (it != held.end()) {
        held.erase(it);
        ReleaseDmabufHold(message.arg0);
      }
    } else if (message.magic == kClientPauseMagic) {
      shm.paused = message.arg0 == 1;
      LOG(INFO) << "Raw frame client of display " << shm.display_number
                << (shm.paused ? " paused" : " resumed");
    } else if (message.magic == kSlotReleaseMagic && shm.generation &&
               message.arg0 == shm.generation &&
               message.arg1 < shm.slot_count) {
      shm.busy_slots &= ~(1u << message.arg1);
    }
  }
}

// Pick the slot for the next frame. If the client releases the slots, wait
// until it has released one.
bool RawFrameStreamer::AcquireShmSlot(int fd, ClientShm& shm,
                                      uint32_t* slot_index) {
  if (!shm.generation) {
    *slot_index = shm.next_slot++ % shm.slot_count;
    return true;
  }

  while (true) {
    if (!ReadClientMessages(fd, shm)) {
      return false;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (uint32_t i = 0; i < shm.slot_count; ++i) {
        const uint32_t index = (shm.next_slot + i) % shm.slot_count;
        if ((shm.busy_slots & (1u << index)) == 0) {
          shm.busy_slots |= 1u << index;
          shm.next_slot = index + 1;
          *slot_index = index;
          return true;
        }
      }
      if (stopped_) {
        return false;
      }
    }
    pollfd pfd = {
        .fd = fd,
        .events = POLLIN,
        .revents = 0,
    };
    if (poll(&pfd, 1, kAcceptPollTimeoutMs) < 0 && errno != EINTR) {
      return false;
    }
  }
}

bool RawFrameStreamer::SendDmabufFrame(int fd, const Frame& frame,
                                       bool with_frame_id) {
  if (frame.dmabuf_fd < 0) {
    return false;
  }

  // Only a client that asked for frame ids knows the longer header
  DmabufFrameIdHeader header = {
      .frame =
          {
              .magic = kDmabufFrameMagic,
              .version = with_frame_id ? kDmabufFrameIdVersion
                                       : kDmabufFrameVersion,
              .display_number = frame.header.display_number,
              .width = frame.header.width,
              .height = frame.header.height,
              .fourcc = frame.header.fourcc,
              .offset = frame.offset,
              .stride_bytes = frame.header.stride_bytes,
              .modifier_hi = frame.modifier_hi,
              .modifier_lo = frame.modifier_lo,
          },
      .frame_id = frame.hold_id,
  };
  const size_t header_size =
      with_frame_id ? sizeof(DmabufFrameIdHeader) : sizeof(DmabufFrameHeader);

  iovec iov = {};
  iov.iov_base = &header;
  iov.iov_len = header_size;

  alignas(struct cmsghdr) char control[CMSG_SPACE(sizeof(int))] = {};
  msghdr msg = {};
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = control;
  msg.msg_controllen = sizeof(control);

  cmsghdr* cmsg = CMSG_FIRSTHDR(&msg);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(sizeof(int));
  memcpy(CMSG_DATA(cmsg), &frame.dmabuf_fd, sizeof(int));

  return SendMessageWithDeadline(fd, &msg, header_size);
}

// Drop the slots. A copy in flight in OnFrame() keeps the mapping until it is
// done, and finds the slots gone when it publishes
void RawFrameStreamer::CloseClientShm(ClientShm& shm) const {
  shm.mapping.reset();
  shm.slot_size = 0;
  shm.slot_count = 0;
  shm.next_slot = 0;
  shm.generation = 0;
  shm.busy_slots = 0;
}

RawFrameStreamer::Frame RawFrameStreamer::CopyLatestFrameLocked(
    DisplayStream& display) {
  Frame& latest_frame = display.latest_frame;
  Frame frame;
  frame.type = latest_frame.type;
  frame.header = latest_frame.header;
  frame.pixels = latest_frame.pixels;
  frame.offset = latest_frame.offset;
  frame.modifier_hi = latest_frame.modifier_hi;
  frame.modifier_lo = latest_frame.modifier_lo;
  // From now on the client holds the slot, until it releases it
  frame.slot = latest_frame.slot;
  if (latest_frame.slot >= 0) {
    latest_frame.slot_sent = true;
  }
  // And the DMA-BUF's buffer likewise
  if (latest_frame.hold_id != 0 && !latest_frame.hold_taken) {
    frame.hold_id = latest_frame.hold_id;
    latest_frame.hold_taken = true;
  }
  if (latest_frame.dmabuf_fd >= 0) {
    frame.dmabuf_fd = fcntl(latest_frame.dmabuf_fd, F_DUPFD_CLOEXEC, 3);
  }
  return frame;
}

void RawFrameStreamer::CloseFrameFd(Frame& frame) const {
  if (frame.dmabuf_fd >= 0) {
    close(frame.dmabuf_fd);
    frame.dmabuf_fd = -1;
  }
}

std::shared_ptr<std::vector<uint8_t>> RawFrameStreamer::AcquireRawBufferLocked(
    size_t size) {
  for (size_t i = 0; i < raw_buffers_.size(); ++i) {
    const size_t index = (next_raw_buffer_ + i) % raw_buffers_.size();
    auto& buffer = raw_buffers_[index];
    if (buffer.use_count() == 1) {
      next_raw_buffer_ = (index + 1) % raw_buffers_.size();
      if (buffer->capacity() < size) {
        buffer->reserve(size);
      }
      return buffer;
    }
  }

  if (raw_buffers_.size() < kRawBufferPoolSize) {
    auto buffer = std::make_shared<std::vector<uint8_t>>();
    buffer->reserve(size);
    raw_buffers_.push_back(buffer);
    next_raw_buffer_ = raw_buffers_.size() % kRawBufferPoolSize;
    return buffer;
  }

  auto buffer = std::make_shared<std::vector<uint8_t>>();
  buffer->reserve(size);
  return buffer;
}

}  // namespace cuttlefish
