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
#include <string>

#include "absl/log/check.h"
#include "absl/log/log.h"
#include "gflags/gflags.h"

#include "cuttlefish/host/frontend/webrtc/raw_frame_streamer.h"
#include "cuttlefish/host/libs/config/logging.h"
#include "cuttlefish/host/libs/screen_connector/wayland_screen_connector.h"

DEFINE_int32(frame_server_fd, -1, "An fd to listen on for frame updates");
DEFINE_string(raw_frame_socket_path, "",
              "Optional unix socket path to stream raw frames for local viewers");
DEFINE_bool(frames_are_rgba, true, "Whether incoming frames use RGBA order");

namespace cuttlefish {
namespace {

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

  RawFrameStreamer raw_frame_streamer(FLAGS_raw_frame_socket_path);
  WaylandScreenConnector screen_connector(FLAGS_frame_server_fd,
                                          FLAGS_frames_are_rgba);
  screen_connector.SetFrameCallback(
      [&raw_frame_streamer](uint32_t display_number, uint32_t frame_width,
                            uint32_t frame_height, uint32_t frame_fourcc_format,
                            uint32_t frame_stride_bytes, uint8_t* frame_bytes) {
        raw_frame_streamer.OnFrame(display_number, frame_width, frame_height,
                                   frame_fourcc_format, frame_stride_bytes,
                                   frame_bytes);
      });

  SleepForever();
}

}  // namespace cuttlefish

int main(int argc, char** argv) {
  return cuttlefish::RawFrameStreamerMain(argc, argv);
}
