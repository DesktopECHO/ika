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

#include <unistd.h>

#include <limits>
#include <memory>
#include <string>

#include "absl/log/check.h"
#include "absl/log/log.h"
#include "cuttlefish/common/libs/fs/shared_fd.h"
#include "cuttlefish/host/frontend/webrtc/audio_handler.h"
#include "cuttlefish/host/frontend/webrtc/audio_stream_config.h"
#include "cuttlefish/host/frontend/webrtc/ika_stream.h"
#include "cuttlefish/host/frontend/webrtc/libcommon/audio_source.h"
#include "cuttlefish/host/frontend/webrtc/pipewire_audio_sink.h"
#include "cuttlefish/host/libs/audio_connector/server.h"
#include "cuttlefish/host/libs/config/cuttlefish_config.h"
#include "cuttlefish/host/libs/config/logging.h"
#include "cuttlefish/host/libs/screen_connector/wayland_screen_connector.h"
#include "gflags/gflags.h"

DEFINE_int32(frame_server_fd, -1, "An fd to listen on for frame updates");
DEFINE_int32(audio_server_fd, -1, "An fd to listen on for audio frames");
DEFINE_string(
    raw_frame_socket_path, "",
    "Optional unix socket path to stream raw frames for local viewers");
DEFINE_bool(frames_are_rgba, true, "Whether incoming frames use RGBA order");

namespace cuttlefish {
namespace {

class SilentAudioSource : public webrtc_streaming::AudioSource {
 public:
  int GetMoreAudioData(void* data, int bytes_per_sample,
                       int samples_per_channel, int num_channels,
                       int sample_rate, bool& muted) override {
    (void)data;
    (void)bytes_per_sample;
    (void)samples_per_channel;
    (void)num_channels;
    (void)sample_rate;
    muted = true;
    return 0;
  }
};

std::unique_ptr<AudioServer> CreateAudioServer(int audio_server_fd) {
  SharedFD server_fd = SharedFD::Dup(audio_server_fd);
  close(audio_server_fd);
  return std::make_unique<AudioServer>(server_fd);
}

std::shared_ptr<AudioHandler> SetupAudio() {
  if (FLAGS_audio_server_fd < 0) {
    return nullptr;
  }

  auto cvd_config = CuttlefishConfig::Get();
  auto instance = cvd_config->ForDefaultInstance();
  if (!instance.enable_audio()) {
    close(FLAGS_audio_server_fd);
    return nullptr;
  }

  auto stream_config = ParseAudioStreamConfig(instance);
  std::shared_ptr<webrtc_streaming::AudioSink> audio_sink =
      std::make_shared<PipeWireAudioSink>("ika", stream_config.mixer_settings);
  std::shared_ptr<webrtc_streaming::AudioSource> audio_source =
      std::make_shared<SilentAudioSource>();
  auto audio_handler = std::make_shared<AudioHandler>(
      CreateAudioServer(FLAGS_audio_server_fd), std::move(audio_sink),
      std::move(audio_source), stream_config.streams,
      stream_config.mixer_settings);
  audio_handler->Start();
  return audio_handler;
}

[[noreturn]] void SleepForever() {
  while (true) {
    sleep(std::numeric_limits<unsigned int>::max());
  }
}

}  // namespace

int RawFrameStreamerMain(int argc, char** argv) {
  DefaultSubprocessLogging(argv);
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  CHECK_GE(FLAGS_frame_server_fd, 0) << "Must specify --frame_server_fd";
  CHECK(!FLAGS_raw_frame_socket_path.empty())
      << "Must specify --raw_frame_socket_path";

  LOG(INFO) << "Starting raw frame streamer on " << FLAGS_raw_frame_socket_path;

  auto audio_handler = SetupAudio();
  if (audio_handler) {
    LOG(INFO) << "Started PipeWire-backed Cuttlefish audio";
  }

  RawFrameStreamer ika_stream(FLAGS_raw_frame_socket_path);
  WaylandScreenConnector screen_connector(FLAGS_frame_server_fd,
                                          FLAGS_frames_are_rgba);
  screen_connector.SetFrameCallback(
      [&ika_stream](uint32_t display_number, uint32_t frame_width,
                    uint32_t frame_height, uint32_t frame_fourcc_format,
                    uint32_t frame_stride_bytes, uint8_t* frame_bytes) {
        ika_stream.OnFrame(display_number, frame_width, frame_height,
                           frame_fourcc_format, frame_stride_bytes,
                           frame_bytes);
      });
  screen_connector.SetDmabufFrameCallback(
      [&ika_stream](uint32_t display_number, uint32_t frame_width,
                    uint32_t frame_height, uint32_t frame_fourcc_format,
                    int dmabuf_fd, uint32_t frame_offset,
                    uint32_t frame_stride_bytes, uint32_t modifier_hi,
                    uint32_t modifier_lo) {
        return ika_stream.OnDmabufFrame(
            display_number, frame_width, frame_height, frame_fourcc_format,
            dmabuf_fd, frame_offset, frame_stride_bytes, modifier_hi,
            modifier_lo);
      });

  SleepForever();
}

}  // namespace cuttlefish

int main(int argc, char** argv) {
  return cuttlefish::RawFrameStreamerMain(argc, argv);
}
