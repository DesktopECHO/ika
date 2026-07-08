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

#include <pipewire/pipewire.h>

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "cuttlefish/host/frontend/webrtc/audio_settings.h"
#include "cuttlefish/host/frontend/webrtc/libdevice/audio_sink.h"

namespace cuttlefish {

class PipeWireAudioSink : public webrtc_streaming::AudioSink {
 public:
  PipeWireAudioSink(std::string node_name,
                    const AudioMixerSettings& mixer_settings);
  ~PipeWireAudioSink() override;

  PipeWireAudioSink(const PipeWireAudioSink&) = delete;
  PipeWireAudioSink& operator=(const PipeWireAudioSink&) = delete;

  void OnFrame(const webrtc_streaming::AudioFrameBuffer& frame,
               int64_t timestamp_us) override;

 private:
  static void OnStateChanged(void* data, pw_stream_state old_state,
                             pw_stream_state state, const char* error);
  static void OnProcess(void* data);

  bool InitPipeWire(const std::string& node_name);
  void Process();
  void WriteLocked(const uint8_t* data, size_t size);
  size_t ReadLocked(uint8_t* data, size_t size);
  void DropLocked(size_t size);

  const uint32_t sample_rate_;
  const uint8_t channels_;
  const size_t frame_size_bytes_;

  pw_thread_loop* thread_loop_ = nullptr;
  pw_stream* stream_ = nullptr;

  std::mutex mutex_;
  std::vector<uint8_t> ring_buffer_;
  size_t read_offset_ = 0;
  size_t write_offset_ = 0;
  size_t buffered_bytes_ = 0;
};

}  // namespace cuttlefish
