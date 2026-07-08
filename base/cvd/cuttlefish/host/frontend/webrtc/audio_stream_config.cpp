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

#include "cuttlefish/host/frontend/webrtc/audio_stream_config.h"

#include <limits>

#include "absl/log/check.h"
#include "absl/log/log.h"
#include "cuttlefish/host/commands/assemble_cvd/proto/guest_config.pb.h"

namespace cuttlefish {
namespace {

AudioChannelsLayout ConvertChannelLayout(
    ::cuttlefish::config::Audio_ChannelLayout layout) {
  using ChannelLayout = ::cuttlefish::config::Audio_ChannelLayout;

  switch (layout) {
    case ChannelLayout::Audio_ChannelLayout_MONO:
      return AudioChannelsLayout::Mono;
    case ChannelLayout::Audio_ChannelLayout_STEREO:
      return AudioChannelsLayout::Stereo;
    case ChannelLayout::Audio_ChannelLayout_SURROUND51:
      return AudioChannelsLayout::Surround51;
    default:
      VLOG(0) << "Unsupported channel layout: " << layout;
  }

  return AudioChannelsLayout::Stereo;
}

uint32_t ConvertSampleRate(::cuttlefish::config::Audio_SampleRate rate) {
  using SampleRate = ::cuttlefish::config::Audio_SampleRate;
  switch (rate) {
    case SampleRate::Audio_SampleRate_RATE_32000:
      return 32000;
    case SampleRate::Audio_SampleRate_RATE_44100:
      return 44100;
    case SampleRate::Audio_SampleRate_RATE_48000:
      return 48000;
    case SampleRate::Audio_SampleRate_RATE_64000:
      return 64000;
    default:
      VLOG(0) << "Unsupported sample rate: " << rate;
  }

  return 48000;
}

AudioStreamSettings ParseAudioStreamSettings(
    const ::cuttlefish::config::Audio_PCMDevice_Stream& stream,
    AudioStreamSettings::Direction direction) {
  const auto id = stream.id();
  CHECK_LE(id, std::numeric_limits<uint8_t>::max());
  AudioStreamSettings settings = {
      .id = static_cast<uint8_t>(id),
      .channels_layout = ConvertChannelLayout(stream.channel_layout()),
      .direction = direction,
  };
  if (stream.has_controls()) {
    const auto& controls = stream.controls();
    settings.has_mute_control = controls.mute_control_enabled();
    if (controls.has_volume_control()) {
      const auto& volume = controls.volume_control();
      settings.master_volume_control = {{
          .min = volume.min(),
          .max = volume.max(),
          .step = volume.step(),
      }};
    }
  }
  return settings;
}

}  // namespace

AudioStreamConfig ParseAudioStreamConfig(
    const CuttlefishConfig::InstanceSpecific& instance) {
  AudioStreamConfig config;
  const auto audio_settings = instance.audio_settings();
  if (!audio_settings.has_value()) {
    const auto output_streams_count = instance.audio_output_streams_count();
    config.streams.push_back(
        {.id = 0,
         .channels_layout = AudioChannelsLayout::Stereo,
         .direction = AudioStreamSettings::Direction::Capture});
    for (auto i = 0; i < output_streams_count; ++i) {
      config.streams.push_back(
          {.id = static_cast<uint8_t>(i),
           .channels_layout = AudioChannelsLayout::Stereo,
           .direction = AudioStreamSettings::Direction::Playback});
    }
    return config;
  }

  CHECK(!audio_settings->pcm_devices().empty());
  if (audio_settings->pcm_devices().size() > 1) {
    LOG(WARNING) << "Only one PCM device is currently supported.";
  }
  const auto& pcm = audio_settings->pcm_devices()[0];
  for (const auto& stream : pcm.playback_streams()) {
    config.streams.push_back(ParseAudioStreamSettings(
        stream, AudioStreamSettings::Direction::Playback));
  }
  for (const auto& stream : pcm.capture_streams()) {
    config.streams.push_back(ParseAudioStreamSettings(
        stream, AudioStreamSettings::Direction::Capture));
  }
  if (pcm.has_mixer()) {
    const auto& mixer = pcm.mixer();
    if (mixer.has_channel_layout()) {
      config.mixer_settings.channels_layout =
          ConvertChannelLayout(mixer.channel_layout());
    }
    if (mixer.has_sample_rate()) {
      config.mixer_settings.sample_rate =
          ConvertSampleRate(mixer.sample_rate());
    }
  }
  return config;
}

}  // namespace cuttlefish
