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

#include "cuttlefish/host/frontend/webrtc/pipewire_audio_source.h"

#include <spa/param/audio/format-utils.h>
#include <spa/param/audio/raw.h>
#include <spa/param/format.h>
#include <spa/pod/builder.h>

#include <algorithm>
#include <cstring>
#include <utility>

#include "absl/log/log.h"

namespace cuttlefish {
namespace {

constexpr size_t kBufferedAudioMs = 100;

void SetChannelPositions(int channels, spa_audio_info_raw& info) {
  if (channels == 1) {
    info.position[0] = SPA_AUDIO_CHANNEL_MONO;
  } else if (channels == 2) {
    info.position[0] = SPA_AUDIO_CHANNEL_FL;
    info.position[1] = SPA_AUDIO_CHANNEL_FR;
  } else {
    for (int i = 0; i < channels; ++i) {
      info.position[i] = SPA_AUDIO_CHANNEL_UNKNOWN;
    }
  }
}

}  // namespace

PipeWireAudioSource::PipeWireAudioSource(std::string node_name)
    : node_name_(std::move(node_name)) {}

PipeWireAudioSource::~PipeWireAudioSource() { Stop(); }

void PipeWireAudioSource::Start(int bytes_per_sample, int num_channels,
                                int sample_rate) {
  std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
  StopLocked();

  if (bytes_per_sample != sizeof(int16_t) || num_channels <= 0 ||
      num_channels > SPA_AUDIO_MAX_CHANNELS || sample_rate <= 0) {
    LOG(ERROR) << "Unsupported guest microphone format: "
               << bytes_per_sample * 8 << " bits, " << sample_rate << " Hz, "
               << num_channels << " channels";
    return;
  }

  {
    std::lock_guard<std::mutex> data_lock(data_mutex_);
    bytes_per_sample_ = bytes_per_sample;
    num_channels_ = num_channels;
    sample_rate_ = sample_rate;
    const size_t frame_size = bytes_per_sample_ * num_channels_;
    ring_buffer_.resize(sample_rate_ * frame_size * kBufferedAudioMs / 1000);
    read_offset_ = 0;
    write_offset_ = 0;
    buffered_bytes_ = 0;
    empty_reads_ = 0;
    missing_source_warning_logged_ = false;
  }

  if (!InitPipeWire(num_channels, sample_rate)) {
    LOG(ERROR) << "PipeWire microphone is unavailable; guest microphone will "
                  "receive silence";
    StopLocked();
    return;
  }

  {
    std::lock_guard<std::mutex> data_lock(data_mutex_);
    active_ = true;
  }
  VLOG(1) << "Opened guest microphone stream (" << sample_rate << " Hz, "
          << num_channels << " channels)";
}

void PipeWireAudioSource::Stop() {
  std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
  StopLocked();
}

void PipeWireAudioSource::StopLocked() {
  {
    std::lock_guard<std::mutex> data_lock(data_mutex_);
    active_ = false;
  }

  if (thread_loop_ != nullptr) {
    pw_thread_loop_stop(thread_loop_);
    pw_thread_loop_lock(thread_loop_);
  }
  if (stream_ != nullptr) {
    pw_stream_destroy(stream_);
    stream_ = nullptr;
  }
  if (thread_loop_ != nullptr) {
    pw_thread_loop_unlock(thread_loop_);
    pw_thread_loop_destroy(thread_loop_);
    thread_loop_ = nullptr;
  }

  std::lock_guard<std::mutex> data_lock(data_mutex_);
  ring_buffer_.clear();
  read_offset_ = 0;
  write_offset_ = 0;
  buffered_bytes_ = 0;
  bytes_per_sample_ = 0;
  num_channels_ = 0;
  sample_rate_ = 0;
  empty_reads_ = 0;
  missing_source_warning_logged_ = false;
}

bool PipeWireAudioSource::InitPipeWire(int num_channels, int sample_rate) {
  pw_init(nullptr, nullptr);

  thread_loop_ = pw_thread_loop_new("ika-microphone", nullptr);
  if (thread_loop_ == nullptr) {
    return false;
  }

  pw_thread_loop_lock(thread_loop_);
  pw_properties* properties = pw_properties_new(
      PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture",
      PW_KEY_MEDIA_ROLE, "Communication", PW_KEY_APP_NAME, "ika",
      PW_KEY_NODE_NAME, node_name_.c_str(), PW_KEY_NODE_DESCRIPTION,
      "ika microphone", PW_KEY_MEDIA_NAME, "ika microphone", nullptr);
  if (properties == nullptr) {
    pw_thread_loop_unlock(thread_loop_);
    return false;
  }

  static const pw_stream_events kStreamEvents = {
      .version = PW_VERSION_STREAM_EVENTS,
      .state_changed = &PipeWireAudioSource::OnStateChanged,
      .process = &PipeWireAudioSource::OnProcess,
  };
  stream_ = pw_stream_new_simple(pw_thread_loop_get_loop(thread_loop_),
                                 node_name_.c_str(), properties, &kStreamEvents,
                                 this);
  if (stream_ == nullptr) {
    pw_properties_free(properties);
    pw_thread_loop_unlock(thread_loop_);
    return false;
  }

  uint8_t buffer[1024];
  spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
  spa_audio_info_raw info = {
      .format = SPA_AUDIO_FORMAT_S16,
      .flags = 0,
      .rate = static_cast<uint32_t>(sample_rate),
      .channels = static_cast<uint32_t>(num_channels),
  };
  SetChannelPositions(num_channels, info);
  const spa_pod* params[] = {
      spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &info),
  };

  const int ret = pw_stream_connect(
      stream_, PW_DIRECTION_INPUT, PW_ID_ANY,
      static_cast<pw_stream_flags>(PW_STREAM_FLAG_AUTOCONNECT |
                                   PW_STREAM_FLAG_MAP_BUFFERS |
                                   PW_STREAM_FLAG_RT_PROCESS),
      params, sizeof(params) / sizeof(params[0]));
  if (ret < 0) {
    pw_stream_destroy(stream_);
    stream_ = nullptr;
    pw_thread_loop_unlock(thread_loop_);
    return false;
  }

  pw_thread_loop_unlock(thread_loop_);
  if (pw_thread_loop_start(thread_loop_) < 0) {
    pw_thread_loop_lock(thread_loop_);
    pw_stream_destroy(stream_);
    stream_ = nullptr;
    pw_thread_loop_unlock(thread_loop_);
    return false;
  }
  return true;
}

int PipeWireAudioSource::GetMoreAudioData(void* data, int bytes_per_sample,
                                          int samples_per_channel,
                                          int num_channels, int sample_rate,
                                          bool& muted) {
  if (data == nullptr || samples_per_channel <= 0) {
    muted = true;
    return -1;
  }

  const size_t requested_bytes = static_cast<size_t>(samples_per_channel) *
                                 bytes_per_sample * num_channels;
  std::lock_guard<std::mutex> data_lock(data_mutex_);
  if (!active_ || bytes_per_sample != bytes_per_sample_ ||
      num_channels != num_channels_ || sample_rate != sample_rate_) {
    muted = true;
    return 0;
  }

  auto* output = static_cast<uint8_t*>(data);
  const size_t copied = ReadLocked(output, requested_bytes);
  if (copied == 0) {
    ++empty_reads_;
    if (empty_reads_ >= 100 && !missing_source_warning_logged_) {
      LOG(WARNING) << "No audio is arriving from PipeWire; ensure the host has "
                      "a default microphone source";
      missing_source_warning_logged_ = true;
    }
    muted = true;
    return 0;
  }
  empty_reads_ = 0;
  if (copied < requested_bytes) {
    std::memset(output + copied, 0, requested_bytes - copied);
  }
  muted = false;
  return samples_per_channel;
}

void PipeWireAudioSource::OnStateChanged(void* data, pw_stream_state old_state,
                                         pw_stream_state state,
                                         const char* error) {
  (void)data;
  (void)old_state;
  if (state == PW_STREAM_STATE_ERROR) {
    LOG(ERROR) << "PipeWire microphone stream error: " << (error ? error : "");
  } else if (state == PW_STREAM_STATE_STREAMING) {
    LOG(INFO) << "Guest microphone connected to the default PipeWire source";
  } else {
    VLOG(1) << "PipeWire microphone stream state: "
            << pw_stream_state_as_string(state);
  }
}

void PipeWireAudioSource::OnProcess(void* data) {
  static_cast<PipeWireAudioSource*>(data)->Process();
}

void PipeWireAudioSource::Process() {
  pw_buffer* buffer = nullptr;
  while ((buffer = pw_stream_dequeue_buffer(stream_)) != nullptr) {
    spa_buffer* spa_buffer = buffer->buffer;
    if (spa_buffer->n_datas == 0 || spa_buffer->datas[0].data == nullptr ||
        spa_buffer->datas[0].chunk == nullptr) {
      pw_stream_queue_buffer(stream_, buffer);
      continue;
    }

    const spa_data& spa_data = spa_buffer->datas[0];
    const uint32_t offset = std::min(spa_data.chunk->offset, spa_data.maxsize);
    const size_t size =
        std::min<size_t>(spa_data.chunk->size, spa_data.maxsize - offset);
    const auto* input = static_cast<const uint8_t*>(spa_data.data) + offset;
    std::unique_lock<std::mutex> data_lock(data_mutex_, std::try_to_lock);
    if (data_lock.owns_lock() && active_) {
      WriteLocked(input, size);
    }
    pw_stream_queue_buffer(stream_, buffer);
  }
}

void PipeWireAudioSource::WriteLocked(const uint8_t* data, size_t size) {
  if (ring_buffer_.empty()) {
    return;
  }
  if (size > ring_buffer_.size()) {
    data += size - ring_buffer_.size();
    size = ring_buffer_.size();
    buffered_bytes_ = 0;
    read_offset_ = 0;
    write_offset_ = 0;
  }
  if (size > ring_buffer_.size() - buffered_bytes_) {
    DropLocked(size - (ring_buffer_.size() - buffered_bytes_));
  }

  size_t remaining = size;
  while (remaining > 0) {
    const size_t chunk =
        std::min(remaining, ring_buffer_.size() - write_offset_);
    std::memcpy(ring_buffer_.data() + write_offset_, data, chunk);
    data += chunk;
    remaining -= chunk;
    write_offset_ = (write_offset_ + chunk) % ring_buffer_.size();
    buffered_bytes_ += chunk;
  }
}

size_t PipeWireAudioSource::ReadLocked(uint8_t* data, size_t size) {
  const size_t read_size = std::min(size, buffered_bytes_);
  size_t remaining = read_size;
  while (remaining > 0) {
    const size_t chunk =
        std::min(remaining, ring_buffer_.size() - read_offset_);
    std::memcpy(data, ring_buffer_.data() + read_offset_, chunk);
    data += chunk;
    remaining -= chunk;
    read_offset_ = (read_offset_ + chunk) % ring_buffer_.size();
    buffered_bytes_ -= chunk;
  }
  return read_size;
}

void PipeWireAudioSource::DropLocked(size_t size) {
  const size_t drop_size = std::min(size, buffered_bytes_);
  read_offset_ = (read_offset_ + drop_size) % ring_buffer_.size();
  buffered_bytes_ -= drop_size;
}

}  // namespace cuttlefish
