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

#include "cuttlefish/host/libs/directories/cache.h"

#include <errno.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include <optional>
#include <string>
#include <string_view>

#include "absl/log/log.h"
#include "android-base/file.h"
#include "fmt/format.h"

#include "cuttlefish/common/libs/fs/fd.h"
#include "cuttlefish/common/libs/utils/files.h"
#include "cuttlefish/files/file_exists.h"
#include "cuttlefish/host/libs/directories/xdg.h"
#include "cuttlefish/host/libs/web/digest.h"
#include "cuttlefish/io/write_exact.h"
#include "cuttlefish/posix/rename.h"
#include "cuttlefish/posix/stat.h"
#include "cuttlefish/posix/strerror.h"
#include "cuttlefish/result/result.h"

namespace cuttlefish {
namespace {

Result<std::string> CvdCacheEntryPath(std::string_view name) {
  return fmt::format("{}/{}", CF_EXPECT(CvdCacheHome()), name);
}

Result<void> WriteAndRename(Fd& fd, std::string_view key,
                            std::string_view result,
                            const std::string& temp_path,
                            const std::string& path) {
  CF_EXPECT(WriteExact(fd, fmt::format("{}\n", key)));
  CF_EXPECT(WriteExact(fd, result));
  CF_EXPECT(Rename(temp_path, path));
  return {};
}

Result<void> WriteEntry(std::string_view name, std::string_view key,
                        std::string_view result) {
  const std::string path = CF_EXPECT(CvdCacheEntryPath(name));
  CF_EXPECT(EnsureDirectoryExists(android::base::Dirname(path), 0700));

  std::string temp_path = path + ".temp.XXXXXX";
  int raw_fd = mkstemp(temp_path.data());
  CF_EXPECTF(raw_fd >= 0, "Failed to create '{}': '{}'", temp_path,
             StrError(errno));
  Fd fd = CF_EXPECT(Fd::Dup(raw_fd));
  CF_EXPECT_EQ(close(raw_fd), 0, StrError(errno));

  Result<void> written = WriteAndRename(fd, key, result, temp_path, path);
  if (!written.has_value()) {
    unlink(temp_path.c_str());
  }
  return written;
}

}  // namespace

std::string CvdCacheKey(std::string_view inputs) { return Sha256Hex(inputs); }

std::string CvdCacheFileStamp(const std::string& path) {
  Result<struct stat, int> st = Stat(path);
  if (!st.has_value()) {
    return fmt::format("{} missing", path);
  }
#ifdef __APPLE__
  const struct timespec& mtime = st->st_mtimespec;
#else
  const struct timespec& mtime = st->st_mtim;
#endif
  return fmt::format("{} size={} mtime={}.{:09} dev={} ino={} mode={:o} uid={} "
                     "gid={} rdev={}",
                     path, st->st_size, mtime.tv_sec, mtime.tv_nsec,
                     st->st_dev, st->st_ino, st->st_mode, st->st_uid,
                     st->st_gid, st->st_rdev);
}

std::optional<std::string> ReadCvdCacheEntry(std::string_view name,
                                             std::string_view key) {
  Result<std::string> path = CvdCacheEntryPath(name);
  if (!path.has_value() || !FileExists(*path)) {
    return std::nullopt;
  }
  Result<std::string> contents = ReadFileContents(*path);
  if (!contents.has_value()) {
    VLOG(0) << "Ignoring the cached " << name << ": " << contents.error();
    return std::nullopt;
  }
  const size_t newline = contents->find('\n');
  if (newline == std::string::npos ||
      std::string_view(*contents).substr(0, newline) != key) {
    return std::nullopt;
  }
  return contents->substr(newline + 1);
}

void WriteCvdCacheEntry(std::string_view name, std::string_view key,
                        std::string_view result) {
  if (Result<void> written = WriteEntry(name, key, result);
      !written.has_value()) {
    VLOG(0) << "Not caching " << name << ": " << written.error();
  }
}

}  // namespace cuttlefish
