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

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "cuttlefish/host/frontend/webrtc/audio_settings.h"
#include "cuttlefish/host/frontend/webrtc/libdevice/audio_sink.h"
#include "cuttlefish/host/frontend/webrtc/pulse_simple.h"

namespace cuttlefish {

// Plays guest audio on a PulseAudio server with a short buffer and no rate
// adaptation: for WSLg, whose server's own clock is the host's, and where
// PipeWire's tunnel resamples (audibly) trying to reach a latency below what
// the RDP client already holds.
class PulseAudioSink : public webrtc_streaming::AudioSink {
 public:
  // Returns nullptr when PulseAudio or the server is unavailable
  static std::unique_ptr<PulseAudioSink> Create(
      std::string server, const AudioMixerSettings& mixer_settings);
  ~PulseAudioSink() override;

  PulseAudioSink(const PulseAudioSink&) = delete;
  PulseAudioSink& operator=(const PulseAudioSink&) = delete;

  void OnFrame(const webrtc_streaming::AudioFrameBuffer& frame,
               int64_t timestamp_us) override;

 private:
  PulseAudioSink(const PulseSimpleApi* api, std::string server,
                 const AudioMixerSettings& mixer_settings);

  pa_simple* Connect();
  void WriterLoop();

  const PulseSimpleApi* const api_;
  const std::string server_;
  const pa_sample_spec spec_;
  const size_t frame_size_bytes_;
  const size_t max_queued_bytes_;

  pa_simple* stream_ = nullptr;
  std::thread writer_;
  std::mutex mutex_;
  std::condition_variable queued_cv_;
  std::vector<uint8_t> queued_;
  bool stop_ = false;
};

}  // namespace cuttlefish
