//
// Copyright (C) 2026 The Android Open Source Project
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace cuttlefish {

// Results that are slow to work out but stay the same while their inputs do,
// kept across launches under CvdCacheHome(). An entry holds one result, for the
// inputs its key was made from. Entries only save time: one that is missing,
// unreadable or made from other inputs reads as a miss, and a failure to write
// one is logged and otherwise ignored.

// Makes a key from a description of everything a result depends on.
std::string CvdCacheKey(std::string_view inputs);

// Describes the file at `path` for a cache key without reading it: its size,
// modification time, inode and permissions, or that it is missing.
std::string CvdCacheFileStamp(const std::string& path);

// Returns entry `name`'s result if it was written with `key`.
std::optional<std::string> ReadCvdCacheEntry(std::string_view name,
                                             std::string_view key);

// Replaces entry `name` with `result`, made from the inputs `key` describes.
void WriteCvdCacheEntry(std::string_view name, std::string_view key,
                        std::string_view result);

}  // namespace cuttlefish
