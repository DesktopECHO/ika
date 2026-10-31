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

#include "cuttlefish/host/frontend/webrtc/pulse_simple.h"

#include <dlfcn.h>
#include <unistd.h>

#include "absl/log/log.h"

namespace cuttlefish {
namespace {

constexpr char kWslgPulseSocket[] = "/mnt/wslg/PulseServer";

template <typename T>
bool LoadSymbol(void* library, const char* name, T& symbol) {
  symbol = reinterpret_cast<T>(dlsym(library, name));
  if (symbol == nullptr) {
    LOG(ERROR) << "libpulse-simple.so.0 lacks " << name;
  }
  return symbol != nullptr;
}

const PulseSimpleApi* LoadPulseSimpleApi() {
  void* library = dlopen("libpulse-simple.so.0", RTLD_NOW | RTLD_LOCAL);
  if (library == nullptr) {
    LOG(WARNING) << "Could not load PulseAudio: " << dlerror();
    return nullptr;
  }
  static PulseSimpleApi api;
  // pa_strerror is libpulse's, which libpulse-simple links
  if (!LoadSymbol(library, "pa_simple_new", api.simple_new) ||
      !LoadSymbol(library, "pa_simple_write", api.simple_write) ||
      !LoadSymbol(library, "pa_simple_read", api.simple_read) ||
      !LoadSymbol(library, "pa_simple_free", api.simple_free) ||
      !LoadSymbol(library, "pa_strerror", api.strerror)) {
    dlclose(library);
    return nullptr;
  }
  return &api;
}

}  // namespace

const PulseSimpleApi* GetPulseSimpleApi() {
  static const PulseSimpleApi* api = LoadPulseSimpleApi();
  return api;
}

const char* WslgPulseServer() {
  return access(kWslgPulseSocket, F_OK) == 0 ? "unix:/mnt/wslg/PulseServer"
                                              : nullptr;
}

}  // namespace cuttlefish
