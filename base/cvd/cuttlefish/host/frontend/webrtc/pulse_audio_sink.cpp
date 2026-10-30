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

#include "cuttlefish/host/frontend/webrtc/pulse_audio_sink.h"

#include <chrono>
#include <utility>

#include "absl/log/log.h"

namespace cuttlefish {
namespace {

// What the server buffers for the stream, on top of its sink's own latency
constexpr uint32_t kServerLatencyMs = 30;
// What may wait here while the server's buffer is full; more is dropped, the
// oldest first, so a stall does not add latency for good
constexpr uint32_t kMaxQueuedMs = 40;
// The stream closes after this long without audio, letting the server's sink
// go idle: WSLg's resets the RDP client's latency only then, which otherwise
// grows to ~250 ms
constexpr auto kIdleTimeout = std::chrono::seconds(1);
constexpr auto kReconnectInterval = std::chrono::seconds(1);

}  // namespace

std::unique_ptr<PulseAudioSink> PulseAudioSink::Create(
    std::string server, const AudioMixerSettings& mixer_settings) {
  const PulseSimpleApi* api = GetPulseSimpleApi();
  if (api == nullptr) {
    return nullptr;
  }
  std::unique_ptr<PulseAudioSink> sink(
      new PulseAudioSink(api, std::move(server), mixer_settings));
  sink->stream_ = sink->Connect();
  if (sink->stream_ == nullptr) {
    return nullptr;
  }
  sink->writer_ = std::thread([sink = sink.get()]() { sink->WriterLoop(); });
  return sink;
}

PulseAudioSink::PulseAudioSink(const PulseSimpleApi* api, std::string server,
                               const AudioMixerSettings& mixer_settings)
    : api_(api),
      server_(std::move(server)),
      spec_{PA_SAMPLE_S16LE, mixer_settings.sample_rate,
            GetChannelsCount(mixer_settings.channels_layout)},
      frame_size_bytes_(spec_.channels * sizeof(int16_t)),
      max_queued_bytes_(spec_.rate * kMaxQueuedMs / 1000 * frame_size_bytes_) {
}

PulseAudioSink::~PulseAudioSink() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stop_ = true;
  }
  queued_cv_.notify_one();
  if (writer_.joinable()) {
    writer_.join();
  }
  if (stream_ != nullptr) {
    api_->simple_free(stream_);
  }
}

pa_simple* PulseAudioSink::Connect() {
  const uint32_t server_bytes =
      spec_.rate * kServerLatencyMs / 1000 * frame_size_bytes_;
  const pa_buffer_attr attr = {
      .maxlength = static_cast<uint32_t>(-1),
      .tlength = server_bytes,
      .prebuf = static_cast<uint32_t>(-1),
      .minreq = static_cast<uint32_t>(-1),
      .fragsize = static_cast<uint32_t>(-1),
  };
  int error = 0;
  pa_simple* stream =
      api_->simple_new(server_.c_str(), "ika", PA_STREAM_PLAYBACK, nullptr,
                       "Android", &spec_, nullptr, &attr, &error);
  if (stream == nullptr) {
    LOG(WARNING) << "Could not play on PulseAudio server " << server_ << ": "
                 << api_->strerror(error);
  }
  return stream;
}

void PulseAudioSink::OnFrame(const webrtc_streaming::AudioFrameBuffer& frame,
                             int64_t timestamp_us) {
  (void)timestamp_us;
  if (frame.bits_per_sample() != 16 || frame.sample_rate() != spec_.rate ||
      frame.channels() != spec_.channels) {
    LOG(WARNING) << "Dropping guest audio frame with unexpected format: "
                 << frame.bits_per_sample() << " bits, " << frame.sample_rate()
                 << " Hz, " << frame.channels() << " channels";
    return;
  }

  const size_t size = static_cast<size_t>(frame.frames()) * frame_size_bytes_;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    queued_.insert(queued_.end(), frame.data(), frame.data() + size);
    if (queued_.size() > max_queued_bytes_) {
      queued_.erase(queued_.begin(),
                    queued_.begin() + (queued_.size() - max_queued_bytes_));
    }
  }
  queued_cv_.notify_one();
}

void PulseAudioSink::WriterLoop() {
  std::vector<uint8_t> writing;
  auto next_connect = std::chrono::steady_clock::now();
  while (true) {
    {
      std::unique_lock<std::mutex> lock(mutex_);
      if (!queued_cv_.wait_for(lock, kIdleTimeout, [this]() {
            return stop_ || !queued_.empty();
          })) {
        lock.unlock();
        if (stream_ != nullptr) {
          api_->simple_free(stream_);
          stream_ = nullptr;
        }
        continue;
      }
      if (stop_) {
        return;
      }
      writing.swap(queued_);
      queued_.clear();
    }

    if (stream_ == nullptr) {
      // Audio that arrives while the server is away is dropped
      const auto now = std::chrono::steady_clock::now();
      if (now < next_connect) {
        continue;
      }
      stream_ = Connect();
      if (stream_ == nullptr) {
        next_connect = now + kReconnectInterval;
        continue;
      }
    }
    // Blocks while the server's buffer is full
    int error = 0;
    if (api_->simple_write(stream_, writing.data(), writing.size(), &error) <
        0) {
      LOG(WARNING) << "Lost PulseAudio server " << server_ << ": "
                   << api_->strerror(error);
      api_->simple_free(stream_);
      stream_ = nullptr;
      next_connect = std::chrono::steady_clock::now() + kReconnectInterval;
    }
  }
}

}  // namespace cuttlefish
