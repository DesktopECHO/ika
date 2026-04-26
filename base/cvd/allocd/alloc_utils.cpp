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
#include "allocd/alloc_utils.h"

#include <stdint.h>

#include <fstream>
#include <string_view>
#include <sstream>
#include <vector>

#include "absl/log/log.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/str_format.h"

#include "allocd/alloc_driver.h"
#include "cuttlefish/common/libs/utils/subprocess.h"
#include "cuttlefish/host/commands/cvd/utils/common.h"
#include "cuttlefish/result/result.h"

#ifdef __linux__
#include <linux/if_tun.h>
#endif

#include <net/if.h>

namespace cuttlefish {
namespace {

// Read upstream DNS servers from the host. Prefers
// /run/systemd/resolve/resolv.conf (real upstreams written by systemd-resolved)
// over /etc/resolv.conf, which typically resolves to a loopback stub address
// (127.0.0.53) unreachable from the VM guest. Falls back to Google DNS.
void GetHostDnsServers(std::string& ipv4_servers, std::string& ipv6_servers) {
  static constexpr std::string_view kFallbackV4 = "8.8.8.8,8.8.4.4";
  static constexpr std::string_view kFallbackV6 =
      "2001:4860:4860::8888,2001:4860:4860::8844";
  static constexpr const char* kCandidates[] = {
      "/run/systemd/resolve/resolv.conf",
      "/etc/resolv.conf",
  };

  std::vector<std::string> v4, v6;
  for (const char* path : kCandidates) {
    std::ifstream f(path);
    if (!f.is_open()) {
      continue;
    }
    std::string line;
    while (std::getline(f, line)) {
      if (line.rfind("nameserver ", 0) != 0) {
        continue;
      }
      std::string addr = line.substr(11);
      // Skip loopback addresses (stub resolvers like 127.0.0.53)
      if (addr.rfind("127.", 0) == 0 || addr == "::1") {
        continue;
      }
      (addr.find(':') != std::string::npos ? v6 : v4).push_back(addr);
    }
    if (!v4.empty() || !v6.empty()) {
      break;
    }
  }

  auto join_at_least_two = [](std::vector<std::string>& servers,
                               std::string_view fallback) -> std::string {
    if (servers.empty()) {
      return std::string(fallback);
    }
    if (servers.size() == 1) {
      servers.push_back(servers[0]);
    }
    std::ostringstream ss;
    for (size_t i = 0; i < servers.size(); ++i) {
      if (i) ss << ',';
      ss << servers[i];
    }
    return ss.str();
  };

  ipv4_servers = join_at_least_two(v4, kFallbackV4);
  ipv6_servers = join_at_least_two(v6, kFallbackV6);
}

}  // namespace

bool CreateEthernetIface(std::string_view name, std::string_view bridge_name) {
  // assume bridge exists

  if (!CreateTap(name)) {
    return false;
  }

  if (!LinkTapToBridge(name, bridge_name).ok()) {
    CleanupEthernetIface(name);
    return false;
  }

  return true;
}

std::string MobileGatewayName(std::string_view ipaddr, uint16_t id) {
  std::stringstream ss;
  ss << ipaddr << "." << (4 * id - 3);
  return ss.str();
}

std::string MobileNetworkName(std::string_view ipaddr,
                              std::string_view netmask, uint16_t id) {
  std::stringstream ss;
  ss << ipaddr << "." << (4 * id - 4) << netmask;
  return ss.str();
}

bool CreateMobileIface(std::string_view name, uint16_t id,
                       std::string_view ipaddr) {
  if (id > kMaxIfaceNameId) {
    LOG(ERROR) << "ID exceeds maximum value to assign a netmask: " << id;
    return false;
  }

  auto netmask = "/30";
  auto gateway = MobileGatewayName(ipaddr, id);
  auto network = MobileNetworkName(ipaddr, netmask, id);

  if (!CreateTap(name)) {
    return false;
  }

  if (!AddGateway(name, gateway, netmask).ok()) {
    DestroyIface(name);
  }

  if (!IptableConfig(network, true).ok()) {
    DestroyGateway(name, gateway, netmask);
    DestroyIface(name);
    return false;
  };

  return true;
}

bool DestroyMobileIface(std::string_view name, uint16_t id,
                        std::string_view ipaddr) {
  if (id > 63) {
    LOG(ERROR) << "ID exceeds maximum value to assign a netmask: " << id;
    return false;
  }

  auto netmask = "/30";
  auto gateway = MobileGatewayName(ipaddr, id);
  auto network = MobileNetworkName(ipaddr, netmask, id);

  IptableConfig(network, false);
  DestroyGateway(name, gateway, netmask);
  return DestroyIface(name);
}

bool DestroyEthernetIface(std::string_view name) { return DestroyIface(name); }

void CleanupEthernetIface(std::string_view name) { DestroyIface(name); }

bool CreateTap(std::string_view name) {
  LOG(INFO) << "Attempt to create tap interface: " << name;
  if (!AddTapIface(name).ok()) {
    LOG(WARNING) << "Failed to create tap interface: " << name;
    return false;
  }

  if (!BringUpIface(name).ok()) {
    LOG(WARNING) << "Failed to bring up tap interface: " << name;
    DeleteIface(name);
    return false;
  }

  return true;
}

#ifdef __linux__
Result<void> ValidateTapInterfaceIsUsable(const std::string& interface_name) {
  constexpr auto kTunTapDev = "/dev/net/tun";

  auto tap_fd = SharedFD::Open(kTunTapDev, O_RDWR | O_NONBLOCK);
  CF_EXPECTF(tap_fd->IsOpen(), "Unable to open tun device: {}",
             tap_fd->StrError());

  struct ifreq ifr;
  memset(&ifr, 0, sizeof(ifr));
  ifr.ifr_flags = IFF_TAP | IFF_NO_PI | IFF_VNET_HDR;
  strncpy(ifr.ifr_name, interface_name.c_str(), IFNAMSIZ);

  int err = tap_fd->Ioctl(TUNSETIFF, &ifr);
  CF_EXPECTF(err == 0, "Unable to connect to {} tap interface: {}",
             interface_name, tap_fd->StrError());

  return {};
}
#endif

bool DestroyIface(std::string_view name) {
  if (!ShutdownIface(name).ok()) {
    LOG(WARNING) << "Failed to shutdown tap interface: " << name;
    // the interface might have already shutdown ... so ignore and try to remove
    // the interface. In the future we could read from the pipe and handle this
    // case more elegantly
  }

  if (!DeleteIface(name).ok()) {
    LOG(WARNING) << "Failed to delete tap interface: " << name;
    return false;
  }

  return true;
}

std::optional<std::string> GetUserName(uid_t uid) {
  passwd* pw = getpwuid(uid);
  if (pw) {
    std::string ret(pw->pw_name);
    return ret;
  }
  return std::nullopt;
}

bool DestroyBridge(std::string_view name) {
  Result<bool> r = BridgeInUse(name);
  if (!r.ok()) {
    return false;
  }

  if (*r) {
    // Bridge is in use. Don't proceed any further.
    return true;
  }

  return DeleteIface(name).ok();
}

bool SetupBridgeGateway(std::string_view bridge_name,
                        std::string_view ipaddr) {
  GatewayConfig config{false, false, false};
  auto gateway = absl::StrFormat("%s.1", ipaddr);
  auto netmask = "/24";
  auto network = absl::StrFormat("%s.0%s", ipaddr, netmask);
  auto dhcp_range = absl::StrFormat("%s.2,%s.255", ipaddr, ipaddr);

  if (!AddGateway(bridge_name, gateway, netmask).ok()) {
    return false;
  }

  config.has_gateway = true;

  if (!StartDnsmasq(bridge_name, gateway, dhcp_range)) {
    CleanupBridgeGateway(bridge_name, ipaddr, config);
    return false;
  }

  config.has_dnsmasq = true;

  // On Fedora/RHEL, firewalld blocks DHCP (UDP port 67) on bridge interfaces
  // unless the interface is in the trusted zone.
  FirewallAddTrustedInterface(bridge_name);
  config.has_firewall = true;

  auto ret = IptableConfig(network, true).ok();
  if (!ret) {
    CleanupBridgeGateway(bridge_name, ipaddr, config);
    LOG(WARNING) << "Failed to setup ip tables";
  }

  return ret;
}

void CleanupBridgeGateway(std::string_view name, std::string_view ipaddr,
                          const GatewayConfig& config) {
  auto gateway = absl::StrFormat("%s.1", ipaddr);
  auto netmask = "/24";
  auto network = absl::StrFormat("%s.0%s", ipaddr, netmask);
  auto dhcp_range = absl::StrFormat("%s.2,%s.255", ipaddr, ipaddr);

  if (config.has_iptable) {
    IptableConfig(network, false);
  }

  if (config.has_firewall) {
    FirewallRemoveTrustedInterface(name);
  }

  if (config.has_dnsmasq) {
    StopDnsmasq(name);
  }

  if (config.has_gateway) {
    DestroyGateway(name, gateway, netmask);
  }
}

bool StartDnsmasq(std::string_view bridge_name, std::string_view gateway,
                  std::string_view dhcp_range) {
  std::string dns_servers, dns6_servers;
  GetHostDnsServers(dns_servers, dns6_servers);

  return Execute(
             {"dnsmasq", "--port=0", "--strict-order", "--except-interface=lo",
              absl::StrCat("--interface=", bridge_name),
              absl::StrCat("--listen-address=", gateway), "--bind-interfaces",
              absl::StrCat("--dhcp-range=", dhcp_range),
              absl::StrCat("--dhcp-option=option:dns-server,", dns_servers),
              absl::StrCat("--dhcp-option=option6:dns-server,", dns6_servers),
              "--conf-file=",
              absl::StrCat("--pid-file=", CvdDir(), "/cuttlefish-dnsmasq-",
                           bridge_name, ".pid"),
              absl::StrCat("--dhcp-leasefile=", CvdDir(),
                           "/cuttlefish-dnsmasq-", bridge_name, ".leases"),
              "--dhcp-no-override"}) == 0;
}

bool StopDnsmasq(std::string_view name) {
  std::ifstream file;
  std::string filename =
      absl::StrFormat("%s/cuttlefish-dnsmasq-%s.pid", CvdDir(), name);
  std::string lease_filename =
      absl::StrFormat("%s/cuttlefish-dnsmasq-%s.leases", CvdDir(), name);
  LOG(INFO) << "stopping dnsmasq for interface: " << name;
  file.open(filename);
  if (!file.is_open()) {
    LOG(INFO) << "dnsmasq file:" << filename
              << " could not be opened, assume dnsmasq has already stopped";
    return true;
  }

  std::string pid;
  file >> pid;
  file.close();

  // TODO: Let's use kill(2) instead of subjecting ourselves to this.
  bool ret = Execute({"kill", pid}) == 0;
  if (ret) {
    LOG(INFO) << "dnsmasq for:" << name << "successfully stopped";
    std::remove(filename.c_str());
    std::remove(lease_filename.c_str());
  } else {
    LOG(WARNING) << "Failed to stop dnsmasq for:" << name;
  }
  return ret;
}

bool CreateEthernetBridgeIface(std::string_view name,
                               std::string_view ipaddr) {
  auto exists = BridgeExists(name);
  if (exists.ok() && *exists) {
    LOG(INFO) << "Bridge " << name
              << " exists already, ensuring it is administratively up.";
    FirewallAddTrustedInterface(name);
    return BringUpIface(name).ok();
  }

  if (!CreateBridge(name).ok()) {
    return false;
  }

  if (!BringUpIface(name).ok()) {
    DestroyBridge(name);
    return false;
  }

  if (!SetupBridgeGateway(name, ipaddr)) {
    DestroyBridge(name);
    return false;
  }

  return true;
}

bool DestroyEthernetBridgeIface(std::string_view name,
                                std::string_view ipaddr) {
  GatewayConfig config{true, true, true, true};

  // Don't need to check if removing some part of the config failed, we need to
  // remove the entire interface, so just ignore any error until the end
  CleanupBridgeGateway(name, ipaddr, config);

  return DestroyBridge(name);
}

}  // namespace cuttlefish
