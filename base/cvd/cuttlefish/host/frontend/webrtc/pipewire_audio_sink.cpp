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

#include "cuttlefish/host/frontend/webrtc/pipewire_audio_sink.h"

#include <spa/param/audio/format-utils.h>
#include <spa/param/audio/raw.h>
#include <spa/param/format.h>
#include <spa/pod/builder.h>

#include <algorithm>
#include <cstring>

#include "absl/log/log.h"

namespace cuttlefish {
namespace {

constexpr size_t kBufferedAudioMs = 200;

void SetChannelPositions(uint8_t channels, spa_audio_info_raw& info) {
  switch (channels) {
    case 1:
      info.position[0] = SPA_AUDIO_CHANNEL_MONO;
      return;
    case 2:
      info.position[0] = SPA_AUDIO_CHANNEL_FL;
      info.position[1] = SPA_AUDIO_CHANNEL_FR;
      return;
    case 6:
      info.position[0] = SPA_AUDIO_CHANNEL_FL;
      info.position[1] = SPA_AUDIO_CHANNEL_FR;
      info.position[2] = SPA_AUDIO_CHANNEL_FC;
      info.position[3] = SPA_AUDIO_CHANNEL_LFE;
      info.position[4] = SPA_AUDIO_CHANNEL_RL;
      info.position[5] = SPA_AUDIO_CHANNEL_RR;
      return;
    default:
      for (uint8_t i = 0; i < channels; ++i) {
        info.position[i] = SPA_AUDIO_CHANNEL_UNKNOWN;
      }
  }
}

}  // namespace

PipeWireAudioSink::PipeWireAudioSink(std::string node_name,
                                     const AudioMixerSettings& mixer_settings)
    : sample_rate_(mixer_settings.sample_rate),
      channels_(GetChannelsCount(mixer_settings.channels_layout)),
      frame_size_bytes_(channels_ * sizeof(int16_t)),
      ring_buffer_(sample_rate_ * frame_size_bytes_ * kBufferedAudioMs / 1000) {
  if (!InitPipeWire(node_name)) {
    LOG(ERROR) << "PipeWire audio is unavailable; guest audio will be dropped";
  }
}

PipeWireAudioSink::~PipeWireAudioSink() {
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
}

bool PipeWireAudioSink::InitPipeWire(const std::string& node_name) {
  pw_init(nullptr, nullptr);

  thread_loop_ = pw_thread_loop_new("ika-audio", nullptr);
  if (thread_loop_ == nullptr) {
    return false;
  }

  pw_thread_loop_lock(thread_loop_);

  pw_properties* properties = pw_properties_new(
      PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Playback",
      PW_KEY_MEDIA_ROLE, "Game", PW_KEY_APP_NAME, "ika", PW_KEY_NODE_NAME,
      node_name.c_str(), PW_KEY_NODE_DESCRIPTION, "ika", nullptr);
  if (properties == nullptr) {
    pw_thread_loop_unlock(thread_loop_);
    return false;
  }

  static const pw_stream_events kStreamEvents = {
      .version = PW_VERSION_STREAM_EVENTS,
      .state_changed = &PipeWireAudioSink::OnStateChanged,
      .process = &PipeWireAudioSink::OnProcess,
  };

  stream_ =
      pw_stream_new_simple(pw_thread_loop_get_loop(thread_loop_),
                           node_name.c_str(), properties, &kStreamEvents, this);
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
      .rate = sample_rate_,
      .channels = channels_,
  };
  SetChannelPositions(channels_, info);
  const spa_pod* params[] = {
      spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &info),
  };

  const int ret = pw_stream_connect(
      stream_, PW_DIRECTION_OUTPUT, PW_ID_ANY,
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

void PipeWireAudioSink::OnFrame(const webrtc_streaming::AudioFrameBuffer& frame,
                                int64_t timestamp_us) {
  (void)timestamp_us;
  if (stream_ == nullptr || ring_buffer_.empty()) {
    return;
  }
  if (frame.bits_per_sample() != 16 || frame.sample_rate() != sample_rate_ ||
      frame.channels() != channels_) {
    LOG(WARNING) << "Dropping guest audio frame with unexpected format: "
                 << frame.bits_per_sample() << " bits, " << frame.sample_rate()
                 << " Hz, " << frame.channels() << " channels";
    return;
  }

  const size_t size = static_cast<size_t>(frame.frames()) * frame_size_bytes_;
  std::lock_guard<std::mutex> lock(mutex_);
  WriteLocked(frame.data(), size);
}

void PipeWireAudioSink::OnStateChanged(void* data, pw_stream_state old_state,
                                       pw_stream_state state,
                                       const char* error) {
  (void)data;
  (void)old_state;
  if (state == PW_STREAM_STATE_ERROR) {
    LOG(ERROR) << "PipeWire audio stream error: " << (error ? error : "");
  } else {
    VLOG(1) << "PipeWire audio stream state: "
            << pw_stream_state_as_string(state);
  }
}

void PipeWireAudioSink::OnProcess(void* data) {
  static_cast<PipeWireAudioSink*>(data)->Process();
}

void PipeWireAudioSink::Process() {
  pw_buffer* buffer = nullptr;
  while ((buffer = pw_stream_dequeue_buffer(stream_)) != nullptr) {
    spa_buffer* spa_buffer = buffer->buffer;
    if (spa_buffer->datas[0].data == nullptr) {
      pw_stream_queue_buffer(stream_, buffer);
      continue;
    }

    const uint32_t requested_frames =
        buffer->requested == 0
            ? spa_buffer->datas[0].maxsize / frame_size_bytes_
            : buffer->requested;
    const size_t requested_bytes = std::min<size_t>(
        static_cast<size_t>(requested_frames) * frame_size_bytes_,
        spa_buffer->datas[0].maxsize);

    uint8_t* output = static_cast<uint8_t*>(spa_buffer->datas[0].data);
    size_t copied = 0;
    std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
    if (lock.owns_lock()) {
      copied = ReadLocked(output, requested_bytes);
    }
    if (copied < requested_bytes) {
      std::memset(output + copied, 0, requested_bytes - copied);
    }

    spa_buffer->datas[0].chunk->offset = 0;
    spa_buffer->datas[0].chunk->stride = frame_size_bytes_;
    spa_buffer->datas[0].chunk->size = requested_bytes;
    pw_stream_queue_buffer(stream_, buffer);
  }
}

void PipeWireAudioSink::WriteLocked(const uint8_t* data, size_t size) {
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

size_t PipeWireAudioSink::ReadLocked(uint8_t* data, size_t size) {
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

void PipeWireAudioSink::DropLocked(size_t size) {
  const size_t drop_size = std::min(size, buffered_bytes_);
  read_offset_ = (read_offset_ + drop_size) % ring_buffer_.size();
  buffered_bytes_ -= drop_size;
}

}  // namespace cuttlefish
