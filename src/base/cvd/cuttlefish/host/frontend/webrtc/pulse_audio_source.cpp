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

#include "cuttlefish/host/frontend/webrtc/pulse_audio_source.h"

#include <algorithm>
#include <cstring>
#include <utility>

#include "absl/log/log.h"

namespace cuttlefish {
namespace {

// Reads are this long, which is also how long Stop() may wait for one
constexpr int kChunkMs = 10;
// What the server buffers for the stream
constexpr uint32_t kServerLatencyMs = 20;
// What may wait here for the guest; more is dropped, the oldest first
constexpr int kMaxBufferedMs = 60;

}  // namespace

PulseAudioSource::PulseAudioSource(std::string server)
    : server_(std::move(server)), api_(GetPulseSimpleApi()) {}

PulseAudioSource::~PulseAudioSource() { Stop(); }

void PulseAudioSource::Start(int bytes_per_sample, int num_channels,
                             int sample_rate) {
  std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
  StopLocked();

  if (api_ == nullptr) {
    return;
  }
  if (bytes_per_sample != sizeof(int16_t) || num_channels <= 0 ||
      num_channels > 32 || sample_rate <= 0) {
    LOG(ERROR) << "Unsupported guest microphone format: "
               << bytes_per_sample * 8 << " bits, " << sample_rate << " Hz, "
               << num_channels << " channels";
    return;
  }

  const size_t frame_size = bytes_per_sample * num_channels;
  const pa_sample_spec spec = {PA_SAMPLE_S16LE,
                               static_cast<uint32_t>(sample_rate),
                               static_cast<uint8_t>(num_channels)};
  const pa_buffer_attr attr = {
      .maxlength = static_cast<uint32_t>(-1),
      .tlength = static_cast<uint32_t>(-1),
      .prebuf = static_cast<uint32_t>(-1),
      .minreq = static_cast<uint32_t>(-1),
      .fragsize = static_cast<uint32_t>(sample_rate * kServerLatencyMs / 1000 *
                                        frame_size),
  };
  int error = 0;
  pa_simple* stream =
      api_->simple_new(server_.c_str(), "ika", PA_STREAM_RECORD, nullptr,
                       "Android microphone", &spec, nullptr, &attr, &error);
  if (stream == nullptr) {
    LOG(ERROR) << "PulseAudio microphone is unavailable (" << server_
               << ": " << api_->strerror(error)
               << "); guest microphone will receive silence";
    return;
  }

  {
    std::lock_guard<std::mutex> data_lock(data_mutex_);
    bytes_per_sample_ = bytes_per_sample;
    num_channels_ = num_channels;
    sample_rate_ = sample_rate;
    max_buffered_bytes_ = sample_rate * kMaxBufferedMs / 1000 * frame_size;
    buffered_.clear();
    active_ = true;
  }
  stop_ = false;
  const size_t chunk_bytes = sample_rate * kChunkMs / 1000 * frame_size;
  reader_ = std::thread(
      [this, stream, chunk_bytes]() { ReaderLoop(stream, chunk_bytes); });
  LOG(INFO) << "Guest microphone connected to PulseAudio server " << server_;
}

void PulseAudioSource::Stop() {
  std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
  StopLocked();
}

void PulseAudioSource::StopLocked() {
  stop_ = true;
  if (reader_.joinable()) {
    reader_.join();
  }
  std::lock_guard<std::mutex> data_lock(data_mutex_);
  active_ = false;
  buffered_.clear();
  bytes_per_sample_ = 0;
  num_channels_ = 0;
  sample_rate_ = 0;
}

void PulseAudioSource::ReaderLoop(pa_simple* stream, size_t chunk_bytes) {
  std::vector<uint8_t> chunk(chunk_bytes);
  while (!stop_) {
    int error = 0;
    if (api_->simple_read(stream, chunk.data(), chunk.size(), &error) < 0) {
      LOG(WARNING) << "Lost the PulseAudio microphone: "
                   << api_->strerror(error);
      break;
    }
    std::lock_guard<std::mutex> data_lock(data_mutex_);
    buffered_.insert(buffered_.end(), chunk.begin(), chunk.end());
    if (buffered_.size() > max_buffered_bytes_) {
      buffered_.erase(buffered_.begin(),
                      buffered_.begin() +
                          (buffered_.size() - max_buffered_bytes_));
    }
  }
  api_->simple_free(stream);
}

int PulseAudioSource::GetMoreAudioData(void* data, int bytes_per_sample,
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
      num_channels != num_channels_ || sample_rate != sample_rate_ ||
      buffered_.empty()) {
    muted = true;
    return 0;
  }

  auto* output = static_cast<uint8_t*>(data);
  const size_t copied = std::min(requested_bytes, buffered_.size());
  std::memcpy(output, buffered_.data(), copied);
  buffered_.erase(buffered_.begin(), buffered_.begin() + copied);
  if (copied < requested_bytes) {
    std::memset(output + copied, 0, requested_bytes - copied);
  }
  muted = false;
  return samples_per_channel;
}

}  // namespace cuttlefish
