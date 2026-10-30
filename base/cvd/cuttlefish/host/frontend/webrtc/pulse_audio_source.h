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

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "cuttlefish/host/frontend/webrtc/libcommon/audio_source.h"
#include "cuttlefish/host/frontend/webrtc/pulse_simple.h"

namespace cuttlefish {

// Records the guest microphone from a PulseAudio server's default source (see
// PulseAudioSink)
class PulseAudioSource : public webrtc_streaming::AudioSource {
 public:
  explicit PulseAudioSource(std::string server);
  ~PulseAudioSource() override;

  PulseAudioSource(const PulseAudioSource&) = delete;
  PulseAudioSource& operator=(const PulseAudioSource&) = delete;

  void Start(int bytes_per_sample, int num_channels, int sample_rate) override;
  void Stop() override;
  int GetMoreAudioData(void* data, int bytes_per_sample,
                       int samples_per_channel, int num_channels,
                       int sample_rate, bool& muted) override;

 private:
  void StopLocked();
  void ReaderLoop(pa_simple* stream, size_t chunk_bytes);

  const std::string server_;
  const PulseSimpleApi* const api_;

  std::mutex lifecycle_mutex_;
  std::thread reader_;
  std::atomic<bool> stop_ = false;

  std::mutex data_mutex_;
  std::vector<uint8_t> buffered_;
  size_t max_buffered_bytes_ = 0;
  int bytes_per_sample_ = 0;
  int num_channels_ = 0;
  int sample_rate_ = 0;
  bool active_ = false;
};

}  // namespace cuttlefish
