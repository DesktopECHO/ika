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

#include <cstddef>
#include <cstdint>

// PulseAudio's simple API, loaded at run time from libpulse-simple.so.0 so
// that hosts without PulseAudio need neither the library nor its headers. The
// declarations are the subset of <pulse/simple.h> Ika uses; their ABI has been
// stable since PulseAudio 0.9.
namespace cuttlefish {

struct pa_simple;

enum pa_sample_format_t : int {
  PA_SAMPLE_S16LE = 3,
};

enum pa_stream_direction_t : int {
  PA_STREAM_PLAYBACK = 1,
  PA_STREAM_RECORD = 2,
};

struct pa_sample_spec {
  pa_sample_format_t format;
  uint32_t rate;
  uint8_t channels;
};

struct pa_buffer_attr {
  uint32_t maxlength;
  uint32_t tlength;
  uint32_t prebuf;
  uint32_t minreq;
  uint32_t fragsize;
};

struct PulseSimpleApi {
  pa_simple* (*simple_new)(const char* server, const char* name,
                           pa_stream_direction_t dir, const char* dev,
                           const char* stream_name, const pa_sample_spec* ss,
                           const void* channel_map, const pa_buffer_attr* attr,
                           int* error);
  int (*simple_write)(pa_simple* s, const void* data, size_t bytes, int* error);
  int (*simple_read)(pa_simple* s, void* data, size_t bytes, int* error);
  void (*simple_free)(pa_simple* s);
  const char* (*strerror)(int error);
};

// The loaded API, or nullptr when libpulse-simple.so.0 is missing
const PulseSimpleApi* GetPulseSimpleApi();

// WSLg's PulseAudio server, which plays on Windows over RDP, when this host
// runs under WSLg; nullptr elsewhere
const char* WslgPulseServer();

}  // namespace cuttlefish
