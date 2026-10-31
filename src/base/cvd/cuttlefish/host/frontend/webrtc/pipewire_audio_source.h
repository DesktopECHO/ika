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

#include "cuttlefish/host/frontend/webrtc/libcommon/audio_source.h"

namespace cuttlefish {

class PipeWireAudioSource : public webrtc_streaming::AudioSource {
 public:
  explicit PipeWireAudioSource(std::string node_name);
  ~PipeWireAudioSource() override;

  PipeWireAudioSource(const PipeWireAudioSource&) = delete;
  PipeWireAudioSource& operator=(const PipeWireAudioSource&) = delete;

  void Start(int bytes_per_sample, int num_channels, int sample_rate) override;
  void Stop() override;
  int GetMoreAudioData(void* data, int bytes_per_sample,
                       int samples_per_channel, int num_channels,
                       int sample_rate, bool& muted) override;

 private:
  static void OnStateChanged(void* data, pw_stream_state old_state,
                             pw_stream_state state, const char* error);
  static void OnProcess(void* data);

  bool InitPipeWire(int num_channels, int sample_rate);
  void StopLocked();
  void Process();
  void WriteLocked(const uint8_t* data, size_t size);
  size_t ReadLocked(uint8_t* data, size_t size);
  void DropLocked(size_t size);

  const std::string node_name_;

  pw_thread_loop* thread_loop_ = nullptr;
  pw_stream* stream_ = nullptr;

  std::mutex lifecycle_mutex_;
  std::mutex data_mutex_;
  std::vector<uint8_t> ring_buffer_;
  size_t read_offset_ = 0;
  size_t write_offset_ = 0;
  size_t buffered_bytes_ = 0;
  int bytes_per_sample_ = 0;
  int num_channels_ = 0;
  int sample_rate_ = 0;
  int empty_reads_ = 0;
  bool missing_source_warning_logged_ = false;
  bool active_ = false;
};

}  // namespace cuttlefish
