/*
 * Copyright (C) 2020 The Android Open Source Project
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
#include "allocd/alloc_driver.h"

#include <cstdint>
#include <fstream>
#include <string_view>

#include "absl/log/log.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/str_format.h"

#include "cuttlefish/common/libs/utils/subprocess.h"
#include "cuttlefish/result/result.h"

namespace cuttlefish {

Result<void> AddTapIface(std::string_view name) {
  CF_EXPECT(Execute({"ip", "tuntap", "add", "dev", std::string(name), "mode",
                     "tap", "group", kCvdNetworkGroupName, "vnet_hdr"}) == 0,
            "AddTapIface");
  return {};
}

Result<void> ShutdownIface(std::string_view name) {
  CF_EXPECT(
      Execute({"ip", "link", "set", "dev", std::string(name), "down"}) == 0,
      "ShutdownIface");
  return {};
}

Result<void> BringUpIface(std::string_view name) {
  CF_EXPECT(Execute({"ip", "link", "set", "dev", std::string(name), "up"}) == 0,
            "ShutdownIface");
  return {};
}

Result<void> AddGateway(std::string_view name, std::string_view gateway,
                        std::string_view netmask) {
  CF_EXPECT(
      Execute({"ip", "addr", "add", std::string(gateway) + std::string(netmask),
               "broadcast", "+", "dev", std::string(name)}) == 0,
      "AddGateway");
  return {};
}

Result<void> DestroyGateway(std::string_view name, std::string_view gateway,
                            std::string_view netmask) {
  CF_EXPECT(
      Execute({"ip", "addr", "del", std::string(gateway) + std::string(netmask),
               "broadcast", "+", "dev", std::string(name)}) == 0,
      "DestroyGateway");
  return {};
}

Result<void> LinkTapToBridge(std::string_view tap_name,
                             std::string_view bridge_name) {
  CF_EXPECT(Execute({"ip", "link", "set", "dev", std::string(tap_name),
                     "master", std::string(bridge_name)}) == 0,
            "LinkTapToBridge");
  return {};
}

Result<void> DeleteIface(std::string_view name) {
  CF_EXPECT(Execute({"ip", "link", "delete", std::string(name)}) == 0,
            "DeleteIface");
  return {};
}

Result<bool> BridgeExists(std::string_view name) {
  return Execute({"ip", "link", "show", std::string(name)}) == 0;
}

Result<bool> BridgeInUse(std::string_view name) {
  return Execute({"sh", "-c",
                  absl::StrCat("[ $(ip link show master ", name,
                               " | wc -l) -ne 0 ]")}) == 0;
}

Result<void> CreateBridge(std::string_view name) {
  CF_EXPECT(Execute({"ip", "link", "add", "name", std::string(name), "type",
                     "bridge", "forward_delay", "0", "stp_state", "0"}) == 0,
            "CreateBridge");
  return {};
}

namespace {
// Idempotent: `nft add table/set/chain` returns success if the object exists.
// The masquerade rule itself is NOT idempotent on `add rule`, so we detect
// it by listing the chain and grep-ing the rule's stable signature; only
// emit `add rule` when absent. cvdalloc runs with ambient capabilities (see
// the FirewallAddTrustedInterface comment below), so the helpers we exec
// inherit CAP_NET_ADMIN the same way `iptables` did.
Result<void> NftEnsureTopology() {
  (void)Execute({"nft", "add", "table", "ip", "cuttlefish"});
  (void)Execute({"nft", "add", "set", "ip", "cuttlefish", "nat_sources",
                 "{ type ipv4_addr; flags interval; }"});
  (void)Execute({"nft", "add", "chain", "ip", "cuttlefish", "postrouting",
                 "{ type nat hook postrouting priority 100; policy accept; }"});
  if (Execute({"sh", "-c",
               "nft list chain ip cuttlefish postrouting 2>/dev/null | "
               "grep -q 'ip saddr @nat_sources masquerade'"}) != 0) {
    (void)Execute({"nft", "add", "rule", "ip", "cuttlefish", "postrouting",
                   "ip", "saddr", "@nat_sources", "masquerade"});
  }
  return {};
}
}  // namespace

Result<void> NftConfig(std::string_view network, bool add) {
  CF_EXPECT(NftEnsureTopology());
  const std::string element =
      std::string("{ ") + std::string(network) + " }";
  CF_EXPECT(Execute({"nft", add ? "add" : "delete", "element", "ip",
                     "cuttlefish", "nat_sources", element}) == 0,
            "NftConfig");
  return {};
}

// On Fedora/RHEL, firewalld zone assignment for these bridge interfaces is
// handled statically via /etc/firewalld/zones/cuttlefish.xml installed by the
// RPM package. Calling firewall-cmd at runtime would require polkit
// authentication (cvdalloc runs with ambient capabilities, not as root, so
// polkit sees uid=user and prompts for credentials). No-ops here; the zone
// file covers it.
void FirewallAddTrustedInterface(std::string_view) {}
void FirewallRemoveTrustedInterface(std::string_view) {}

}  // namespace cuttlefish
