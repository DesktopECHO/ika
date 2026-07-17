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

#include "cuttlefish/host/libs/process_monitor/process_monitor.h"

#include <set>
#include <string>
#include <utility>

#include "cuttlefish/common/libs/fs/shared_fd.h"
#include "cuttlefish/common/libs/utils/subprocess.h"
#include "cuttlefish/host/libs/feature/command_source.h"
#include "cuttlefish/result/result.h"
#include "gtest/gtest.h"

namespace cuttlefish {
namespace {

Result<ProcessMonitorExit> RunMonitoredExit(int exit_code,
                                            std::set<int> expected_exit_codes,
                                            bool restart_subprocesses = false) {
  Command command("/bin/sh");
  command.AddParameter("-c");
  command.AddParameter("exit " + std::to_string(exit_code));

  ProcessMonitor::Properties properties;
  properties.RestartSubprocesses(restart_subprocesses);
  properties.AddCommand(MonitorCommand(std::move(command),
                                       /* is_critical= */ true,
                                       std::move(expected_exit_codes)));

  ProcessMonitor monitor(std::move(properties), SharedFD());
  CF_EXPECT(monitor.StartAndMonitorProcesses());
  return monitor.WaitForMonitor();
}

TEST(ProcessMonitorTest, ExpectedCriticalExitIsClean) {
  auto result = RunMonitoredExit(0, {0});

  ASSERT_TRUE(result.ok()) << result.error().Trace();
  EXPECT_EQ(*result, ProcessMonitorExit::kExpected);
}

TEST(ProcessMonitorTest, ExpectedCriticalExitIsNotRestarted) {
  auto result = RunMonitoredExit(0, {0}, /* restart_subprocesses= */ true);

  ASSERT_TRUE(result.ok()) << result.error().Trace();
  EXPECT_EQ(*result, ProcessMonitorExit::kExpected);
}

TEST(ProcessMonitorTest, UnlistedCriticalExitRemainsUnexpected) {
  auto result = RunMonitoredExit(7, {0});

  ASSERT_TRUE(result.ok()) << result.error().Trace();
  EXPECT_EQ(*result, ProcessMonitorExit::kUnexpected);
}

TEST(ProcessMonitorTest, UnannotatedZeroExitRemainsUnexpected) {
  auto result = RunMonitoredExit(0, {});

  ASSERT_TRUE(result.ok()) << result.error().Trace();
  EXPECT_EQ(*result, ProcessMonitorExit::kUnexpected);
}

}  // namespace
}  // namespace cuttlefish
