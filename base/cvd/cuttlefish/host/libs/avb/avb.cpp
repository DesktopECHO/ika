/*
 * Copyright 2023 The Android Open Source Project
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
 *
 */

#include "cuttlefish/host/libs/avb/avb.h"

#include <fcntl.h>
#include <stddef.h>
#include <sys/types.h>

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "absl/strings/str_cat.h"
#include "absl/strings/str_join.h"
#include "android-base/file.h"

#include "cuttlefish/common/libs/fs/fd.h"
#include "cuttlefish/common/libs/utils/files.h"
#include "cuttlefish/host/libs/directories/cache.h"
#include "cuttlefish/host/libs/config/known_paths.h"
#include "cuttlefish/process/command.h"
#include "cuttlefish/result/result.h"

namespace cuttlefish {
namespace {

constexpr char kAddHashFooter[] = "add_hash_footer";
constexpr char kDefaultAlgorithm[] = "SHA256_RSA4096";
constexpr char kMakeVbmetaImage[] = "make_vbmeta_image";
// Taken from external/avb/libavb/avb_slot_verify.c; this define is not in the
// headers
constexpr size_t kVbMetaMaxSize = 65536ul;

// avbtool takes a few tenths of a second to start, most of the time it takes
// to sign the small images that are assembled at every launch. These are
// usually the same as at the last launch, so what avbtool made from one is
// kept, and used again for the same inputs.
constexpr off_t kMaxCachedImageSize = 1 << 20;

Result<void> ReplaceFileContents(const std::string& path,
                                 const std::string& contents) {
  CF_EXPECTF(android::base::WriteStringToFile(contents, path),
             "Failed to write '{}'", path);
  return {};
}

}  // namespace

Avb::Avb() : Avb(AvbToolBinary(), kDefaultAlgorithm, TestKeyRsa4096()) {}

Avb::Avb(std::string avbtool_path)
    : Avb(std::move(avbtool_path), kDefaultAlgorithm, TestKeyRsa4096()) {}

Avb::Avb(std::string avbtool_path, std::string algorithm, std::string key)
    : avbtool_path_(std::move(avbtool_path)),
      algorithm_(std::move(algorithm)),
      key_(std::move(key)) {}

Command Avb::GenerateAddHashFooter(const std::string& image_path,
                                   const std::string& partition_name,
                                   const off_t partition_size_bytes) const {
  Command command(avbtool_path_);
  command.AddParameter(kAddHashFooter);
  if (!algorithm_.empty()) {
    command.AddParameter("--algorithm");
    command.AddParameter(algorithm_);
  }
  if (!key_.empty()) {
    command.AddParameter("--key");
    command.AddParameter(key_);
  }
  command.AddParameter("--image");
  command.AddParameter(image_path);
  command.AddParameter("--partition_name");
  command.AddParameter(partition_name);
  if (partition_size_bytes > 0) {
    command.AddParameter("--partition_size");
    command.AddParameter(partition_size_bytes);
  } else {
    command.AddParameter("--dynamic_partition_size");
  }
  return command;
}

std::string Avb::CacheKeyInputs(std::string_view operation) const {
  return absl::StrCat(operation, "\n", CvdCacheFileStamp(avbtool_path_), "\n",
                      algorithm_, "\n", CvdCacheFileStamp(key_), "\n");
}

Result<void> Avb::AddHashFooter(const std::string& image_path,
                                const std::string& partition_name,
                                const off_t partition_size_bytes) const {
  const std::string cache_entry =
      absl::StrCat("avb/", kAddHashFooter, "/", partition_name, "/",
                   android::base::Basename(image_path));
  std::optional<std::string> cache_key;
  if (FileSize(image_path) <= kMaxCachedImageSize) {
    if (Result<std::string> image = ReadFileContents(image_path);
        image.has_value()) {
      cache_key = CvdCacheKey(absl::StrCat(
          CacheKeyInputs(kAddHashFooter), partition_name, "\n",
          partition_size_bytes, "\n", CvdCacheKey(*image), "\n"));
    }
  }
  if (cache_key.has_value()) {
    if (std::optional<std::string> signed_image =
            ReadCvdCacheEntry(cache_entry, *cache_key)) {
      CF_EXPECT(ReplaceFileContents(image_path, *signed_image));
      return {};
    }
  }

  auto command =
      GenerateAddHashFooter(image_path, partition_name, partition_size_bytes);
  int exit_code = command.Start().Wait();
  CF_EXPECTF(exit_code == 0, "Failure running {} {}. Exited with status {}",
             command.Executable(), kAddHashFooter, exit_code);

  if (cache_key.has_value()) {
    if (Result<std::string> signed_image = ReadFileContents(image_path);
        signed_image.has_value()) {
      WriteCvdCacheEntry(cache_entry, *cache_key, *signed_image);
    }
  }
  return {};
}

Command Avb::GenerateMakeVbMetaImage(
    const std::string& output_path,
    const std::vector<ChainPartition>& chained_partitions,
    const std::vector<std::string>& included_partitions,
    const std::vector<std::string>& extra_arguments) {
  Command command(avbtool_path_);
  command.AddParameter(kMakeVbmetaImage);
  command.AddParameter("--algorithm");
  command.AddParameter(algorithm_);
  command.AddParameter("--key");
  command.AddParameter(key_);
  command.AddParameter("--output");
  command.AddParameter(output_path);

  for (const auto& partition : chained_partitions) {
    const std::string argument = partition.name + ":" +
                                 partition.rollback_index + ":" +
                                 partition.key_path;
    command.AddParameter("--chain_partition");
    command.AddParameter(argument);
  }
  for (const auto& partition : included_partitions) {
    command.AddParameter("--include_descriptors_from_image");
    command.AddParameter(partition);
  }
  for (const auto& extra_arg : extra_arguments) {
    command.AddParameter(extra_arg);
  }
  return command;
}

Result<void> Avb::MakeVbMetaImage(
    const std::string& output_path,
    const std::vector<ChainPartition>& chained_partitions,
    const std::vector<std::string>& included_partitions,
    const std::vector<std::string>& extra_arguments) {
  const std::string cache_entry = absl::StrCat(
      "avb/", kMakeVbmetaImage, "/", android::base::Basename(output_path));
  // Descriptors included from other images would need those images read to
  // make a key, so only vbmeta images made of chained partitions are kept.
  std::optional<std::string> cache_key;
  if (included_partitions.empty()) {
    std::string inputs = CacheKeyInputs(kMakeVbmetaImage);
    for (const auto& partition : chained_partitions) {
      absl::StrAppend(&inputs, partition.name, ":", partition.rollback_index,
                      ":", CvdCacheFileStamp(partition.key_path), "\n");
    }
    absl::StrAppend(&inputs, absl::StrJoin(extra_arguments, "\n"), "\n");
    cache_key = CvdCacheKey(inputs);

    if (std::optional<std::string> vbmeta =
            ReadCvdCacheEntry(cache_entry, *cache_key)) {
      CF_EXPECT(ReplaceFileContents(output_path, *vbmeta));
      CF_EXPECT(EnforceVbMetaSize(output_path));
      return {};
    }
  }

  auto command = GenerateMakeVbMetaImage(output_path, chained_partitions,
                                         included_partitions, extra_arguments);
  int exit_code = command.Start().Wait();
  CF_EXPECTF(exit_code == 0, "Failure running {} {}. Exited with status {}",
             command.Executable(), kMakeVbmetaImage, exit_code);
  CF_EXPECT(EnforceVbMetaSize(output_path));

  if (cache_key.has_value()) {
    if (Result<std::string> vbmeta = ReadFileContents(output_path);
        vbmeta.has_value()) {
      WriteCvdCacheEntry(cache_entry, *cache_key, *vbmeta);
    }
  }
  return {};
}

Result<void> EnforceVbMetaSize(const std::string& path) {
  const auto vbmeta_size = FileSize(path);
  CF_EXPECT_LE(vbmeta_size, kVbMetaMaxSize);
  if (vbmeta_size != kVbMetaMaxSize) {
    Fd vbmeta_fd = CF_EXPECT(Fd::Open(path, O_RDWR));
    CF_EXPECTF(vbmeta_fd.Truncate(kVbMetaMaxSize),
               "Truncating {} failed with error {}", path,
               vbmeta_fd.StrError());
    CF_EXPECTF(vbmeta_fd.Fsync() == 0, "fsync on {} failed with error {}", path,
               vbmeta_fd.StrError());
  }
  return {};
}

}  // namespace cuttlefish
