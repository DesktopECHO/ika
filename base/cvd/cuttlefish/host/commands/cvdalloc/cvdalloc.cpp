/*
 * Copyright (C) 2025 The Android Open Source Project
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

#include <errno.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

#include <string_view>
#include <utility>
#include <vector>

#include "absl/cleanup/cleanup.h"
#include "absl/flags/flag.h"
#include "absl/flags/parse.h"
#include "absl/log/log.h"
#include "absl/strings/str_format.h"

#include "allocd/alloc_utils.h"
#include "cuttlefish/common/libs/fs/fd.h"
#include "cuttlefish/common/libs/fs/shared_fd.h"
#include "cuttlefish/host/commands/cvdalloc/interface.h"
#include "cuttlefish/host/commands/cvdalloc/privilege.h"
#include "cuttlefish/host/commands/cvdalloc/sem.h"
#include "cuttlefish/posix/strerror.h"
#include "cuttlefish/result/expect.h"
#include "cuttlefish/result/result_type.h"

ABSL_FLAG(int, id, 0, "Id");
ABSL_FLAG(int, socket, 0, "Socket");
ABSL_FLAG(bool, enable_mobile, true, "Allocate the mobile tap interface.");
ABSL_FLAG(bool, enable_wifi, true, "Allocate the wifi tap interfaces.");

namespace cuttlefish {
namespace {

void Usage() {
  LOG(ERROR) << "cvdalloc --id=id --socket=fd ";
  LOG(ERROR) << "Should only be invoked from run_cvd.";
}

bool IfaceExists(const std::string& name) {
  return access(absl::StrFormat("/sys/class/net/%s", name).c_str(), F_OK) == 0;
}

// A cvdalloc killed before its teardown (for example with its VM) leaves this
// instance's tap interfaces behind, and creating them again fails. Removes
// them; the bridges are shared with other instances and reused as they are.
void RemoveStaleTaps(int id, bool enable_mobile, bool enable_wifi) {
  if (enable_mobile && IfaceExists(CvdallocInterfaceName("mtap", id))) {
    LOG(INFO) << "cvdalloc: removing stale " << CvdallocInterfaceName("mtap", id);
    DestroyMobileIface(CvdallocInterfaceName("mtap", id), id,
                       kCvdallocMobileIpPrefix);
  }
  if (enable_wifi && IfaceExists(CvdallocInterfaceName("wtap", id))) {
    LOG(INFO) << "cvdalloc: removing stale " << CvdallocInterfaceName("wtap", id);
    DestroyEthernetIface(CvdallocInterfaceName("wtap", id));
  }
  if (enable_wifi && IfaceExists(CvdallocInterfaceName("wifiap", id))) {
    LOG(INFO) << "cvdalloc: removing stale " << CvdallocInterfaceName("wifiap", id);
    DestroyMobileIface(CvdallocInterfaceName("wifiap", id), id,
                       kCvdallocWirelessApIpPrefix);
  }
  if (IfaceExists(CvdallocInterfaceName("etap", id))) {
    LOG(INFO) << "cvdalloc: removing stale " << CvdallocInterfaceName("etap", id);
    DestroyEthernetIface(CvdallocInterfaceName("etap", id));
  }
}

Result<void> Allocate(int id, std::string_view ethernet_bridge_name,
                      std::string_view wireless_bridge_name,
                      bool enable_mobile, bool enable_wifi) {
  LOG(INFO) << "cvdalloc: allocating network resources";

  if (enable_mobile) {
    CF_EXPECT(CreateMobileIface(CvdallocInterfaceName("mtap", id), id,
                                kCvdallocMobileIpPrefix));
  }
  if (enable_wifi) {
    CF_EXPECT(CreateEthernetBridgeIface(wireless_bridge_name,
                                        kCvdallocWirelessIpPrefix));
    CF_EXPECT(CreateEthernetIface(CvdallocInterfaceName("wtap", id),
                                  wireless_bridge_name));
    CF_EXPECT(CreateMobileIface(CvdallocInterfaceName("wifiap", id), id,
                                kCvdallocWirelessApIpPrefix));
  }
  CF_EXPECT(CreateEthernetBridgeIface(ethernet_bridge_name,
                                      kCvdallocEthernetIpPrefix));
  CF_EXPECT(CreateEthernetIface(CvdallocInterfaceName("etap", id),
                                ethernet_bridge_name));

  return {};
}

Result<void> Teardown(int id, std::string_view ethernet_bridge_name,
                      std::string_view wireless_bridge_name,
                      bool enable_mobile, bool enable_wifi) {
  LOG(INFO) << "cvdalloc: tearing down resources";

  if (enable_mobile) {
    DestroyMobileIface(CvdallocInterfaceName("mtap", id), id,
                       kCvdallocMobileIpPrefix);
  }
  if (enable_wifi) {
    DestroyEthernetIface(CvdallocInterfaceName("wtap", id));
    DestroyMobileIface(CvdallocInterfaceName("wifiap", id), id,
                       kCvdallocWirelessApIpPrefix);
    DestroyBridge(wireless_bridge_name);
  }
  DestroyEthernetIface(CvdallocInterfaceName("etap", id));
  DestroyBridge(ethernet_bridge_name);

  return {};
}

}  // namespace

Result<int> CvdallocMain(int argc, char* argv[]) {
  std::vector<char*> args = absl::ParseCommandLine(argc, argv);

  if (absl::GetFlag(FLAGS_id) == 0 || absl::GetFlag(FLAGS_socket) == 0) {
    Usage();
    /* No need to dump a trace for usage. */
    return 1;
  }

  int id = absl::GetFlag(FLAGS_id);
  bool enable_mobile = absl::GetFlag(FLAGS_enable_mobile);
  bool enable_wifi = absl::GetFlag(FLAGS_enable_wifi);

  SharedFD sock = CF_EXPECT(Fd::Dup(absl::GetFlag(FLAGS_socket)));
  int r = TEMP_FAILURE_RETRY(close(absl::GetFlag(FLAGS_socket)));
  if (r == -1) {
    return CF_ERRNO("close: " << StrError(errno));
  }

  absl::Cleanup shutdown = [sock]() { sock->Shutdown(SHUT_RDWR); };

  /*
   * Save our current uid, so we can restore it to drop privileges later.
   */
  uid_t orig = getuid();

  absl::Cleanup drop_privileges = [orig]() {
    int r = DropPrivileges(orig);
    if (r == -1) {
      LOG(ERROR) << "cvdalloc: couldn't drop privileges: " << StrError(errno);
    }
  };

  r = BeginElevatedPrivileges();
  if (r == -1) {
    return CF_ERRF("Couldn't elevate permissions: {}", StrError(errno));
  }

  absl::Cleanup teardown = [id, enable_mobile, enable_wifi]() {
    LOG(INFO) << "cvdalloc: teardown started";
    // TODO: b/471069557 - diagnose unused
    Result<void> unused =
        Teardown(id, kCvdallocEthernetBridgeName, kCvdallocWirelessBridgeName,
                 enable_mobile, enable_wifi);
  };

  RemoveStaleTaps(id, enable_mobile, enable_wifi);
  CF_EXPECT(Allocate(id, kCvdallocEthernetBridgeName,
                     kCvdallocWirelessBridgeName, enable_mobile, enable_wifi));
  CF_EXPECT(cvdalloc::Post(sock));

  LOG(INFO) << "cvdalloc: waiting to teardown";

  CF_EXPECT(cvdalloc::Wait(sock, cvdalloc::kSemNoTimeout));
  std::move(teardown).Invoke();
  CF_EXPECT(cvdalloc::Post(sock));

  return 0;
}

}  // namespace cuttlefish

int main(int argc, char* argv[]) {
  auto res = cuttlefish::CvdallocMain(argc, argv);
  if (!res.has_value()) {
    LOG(ERROR) << "cvdalloc failed: \n" << res.error();
    abort();
  }

  return *res;
}
