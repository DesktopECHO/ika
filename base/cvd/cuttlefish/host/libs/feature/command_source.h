//
// Copyright (C) 2019 The Android Open Source Project
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

#include <set>
#include <utility>
#include <vector>

#include <fruit/fruit.h>

#include "cuttlefish/common/libs/utils/subprocess.h"
#include "cuttlefish/host/libs/feature/feature.h"
#include "cuttlefish/result/result.h"

namespace cuttlefish {

enum class ProcessCategory {
  kNonCriticalSupport,
  kCriticalSupport,
  kVmm,
};

struct MonitorCommand {
  Command command;
  bool is_critical;
  ProcessCategory category;
  // Exit codes that count as a normal exit. The VMM exiting with one of them
  // ends the process monitor successfully. A non-critical command exiting with
  // one is not restarted. Other critical commands ignore these codes: any exit
  // of theirs is a crash.
  std::set<int> expected_exit_codes;

  MonitorCommand(Command command, bool is_critical = true,
                 std::set<int> expected_exit_codes = {})
      : command(std::move(command)),
        is_critical(is_critical),
        category(is_critical ? ProcessCategory::kCriticalSupport
                             : ProcessCategory::kNonCriticalSupport),
        expected_exit_codes(std::move(expected_exit_codes)) {}

  MonitorCommand(Command command, ProcessCategory category)
      : command(std::move(command)),
        is_critical(category != ProcessCategory::kNonCriticalSupport),
    category(category),
    expected_exit_codes(category == ProcessCategory::kVmm
          ? std::set<int>{0}
          : std::set<int>{}) {}
};

class CommandSource : public virtual SetupFeature {
 public:
  virtual ~CommandSource() = default;
  virtual Result<std::vector<MonitorCommand>> Commands() = 0;
};

class StatusCheckCommandSource : public virtual CommandSource {
 public:
  virtual Result<void> WaitForAvailability() = 0;
};

}  // namespace cuttlefish
