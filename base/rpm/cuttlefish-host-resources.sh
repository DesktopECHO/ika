#!/usr/bin/env bash

set -euo pipefail

modprobe bridge 2>/dev/null || true

if [ -f /etc/sysconfig/cuttlefish-host-resources ]; then
  . /etc/sysconfig/cuttlefish-host-resources
fi

num_cvd_accounts=${num_cvd_accounts:-10}
wifi_bridge_interface=${wifi_bridge_interface:-cvd-wbr}
ethernet_bridge_interface=${ethernet_bridge_interface:-cvd-ebr}
ipv4_bridge=${ipv4_bridge:-1}
ipv6_bridge=${ipv6_bridge:-1}
dns_servers=${dns_servers:-8.8.8.8,8.8.4.4}
dns6_servers=${dns6_servers:-2001:4860:4860::8888,2001:4860:4860::8844}

create_bridges=0
if [ -z "${bridge_interface:-}" ]; then
  create_bridges=1
else
  wifi_bridge_interface=${bridge_interface}
  ethernet_bridge_interface=${bridge_interface}
fi

nmcli=$(command -v nmcli || true)

# The host-resources networking helpers use native nft(8) exclusively.
# iptables-nft and ebtables(-nft) are no longer invoked; everything is
# expressed as a single `ip cuttlefish` table with one masquerade chain
# (rule references a named CIDR set) plus the existing `bridge filter`
# table for the bridged-interface drops. nft has been a hard Requires of
# the cuttlefish-base RPM since this change landed; if it is somehow
# missing on the host this script will fail loudly.
command -v nft >/dev/null 2>&1 || {
  echo "cuttlefish-host-resources: 'nft' is required but not found in PATH" >&2
  exit 1
}

# Idempotent topology: ip cuttlefish / nat_sources set / postrouting chain
# with a single 'ip saddr @nat_sources masquerade' rule. `add table/set/chain`
# are no-ops if the object exists. The masquerade rule is not idempotent on
# `add rule`, so it is added once on first call and detected by string match
# thereafter.
ensure_nft_topology() {
  nft add table ip cuttlefish 2>/dev/null || true
  nft add set ip cuttlefish nat_sources '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
  nft add chain ip cuttlefish postrouting '{ type nat hook postrouting priority 100; policy accept; }' 2>/dev/null || true
  if ! nft list chain ip cuttlefish postrouting 2>/dev/null | grep -q 'ip saddr @nat_sources masquerade'; then
    nft add rule ip cuttlefish postrouting ip saddr @nat_sources masquerade 2>/dev/null || true
  fi
  # Bridge filter chain for per-tap ipv4/ipv6 drops (replaces ebtables).
  nft add table bridge filter 2>/dev/null || true
  nft add chain bridge filter FORWARD '{ type filter hook forward priority 0; }' 2>/dev/null || true
}

nat_add() {
  ensure_nft_topology
  nft add element ip cuttlefish nat_sources "{ $1 }" 2>/dev/null || true
}

nat_del() {
  nft delete element ip cuttlefish nat_sources "{ $1 }" 2>/dev/null || true
}

mkdir -p /run /var/run

mark_unmanaged() {
  local iface="$1"
  if [ -n "$nmcli" ]; then
    "$nmcli" device set "$iface" managed no >/dev/null 2>&1 || true
  fi
}

start_dnsmasq() {
  local ipv6_args=""
  if [ -n "${4:-}" ] && [ -n "${5:-}" ]; then
    ipv6_args="--dhcp-range=${4},ra-stateless,${5} --enable-ra"
  fi
  dnsmasq \
    --port=0 \
    --strict-order \
    --except-interface=lo \
    --interface="$1" \
    --listen-address="$2" \
    --bind-interfaces \
    --dhcp-range="$3" \
    --dhcp-option="option:dns-server,${dns_servers}" \
    --dhcp-option="option6:dns-server,${dns6_servers}" \
    --conf-file="" \
    --pid-file=/var/run/cuttlefish-dnsmasq-"$1".pid \
    --dhcp-leasefile=/var/run/cuttlefish-dnsmasq-"$1".leases \
    --dhcp-no-override \
    ${ipv6_args}
}

stop_dnsmasq() {
  if [ -f /var/run/cuttlefish-dnsmasq-"$1".pid ]; then
    kill "$(cat /var/run/cuttlefish-dnsmasq-"$1".pid)"
    rm -f /var/run/cuttlefish-dnsmasq-"$1".pid
    rm -f /var/run/cuttlefish-dnsmasq-"$1".leases
  fi
}

create_tap() {
  ip tuntap add dev "$1" mode tap group cvdnetwork vnet_hdr
  ip link set dev "$1" up
  mark_unmanaged "$1"
}

destroy_tap() {
  ip link set dev "$1" down || true
  ip link delete "$1" || true
}

create_interface() {
  local tap="$1"
  local gateway="$2.$((4*$3 - 3))"
  local netmask="/30"
  local network="$2.$((4*$3 - 4))${netmask}"
  local ipv6_prefix="${4:-}"
  local ipv6_prefix_length="${5:-}"

  create_tap "$tap"
  ip addr add "${gateway}${netmask}" broadcast + dev "$tap"
  if [ -n "$ipv6_prefix" ] && [ -n "$ipv6_prefix_length" ]; then
    ip -6 addr add "${ipv6_prefix}1/${ipv6_prefix_length}" dev "$tap"
  fi
  nat_add "$network"
}

destroy_interface() {
  local tap="$1"
  local gateway="$2.$((4*$3 - 3))"
  local netmask="/30"
  local network="$2.$((4*$3 - 4))${netmask}"
  local ipv6_prefix="${4:-}"
  local ipv6_prefix_length="${5:-}"

  nat_del "$network"
  ip addr del "${gateway}${netmask}" dev "$tap" || true
  if [ -n "$ipv6_prefix" ] && [ -n "$ipv6_prefix_length" ]; then
    ip -6 addr del "${ipv6_prefix}1/${ipv6_prefix_length}" dev "$tap" || true
  fi
  destroy_tap "$tap"
}

create_bridged_interfaces() {
  if [ "$create_bridges" = "1" ]; then
    ip link add name "$2" type bridge forward_delay 0 stp_state 0
    ip link set dev "$2" up
    mark_unmanaged "$2"
    echo 0 > /proc/sys/net/ipv6/conf/$2/disable_ipv6
    echo 0 > /proc/sys/net/ipv6/conf/$2/addr_gen_mode
    echo 1 > /proc/sys/net/ipv6/conf/$2/autoconf
  fi

  for i in $(seq ${num_cvd_accounts}); do
    tap="$(printf "$3-%02d" "$i")"
    create_tap "$tap"
    ip link set dev "$tap" master "$2"
    if [ "$create_bridges" != "1" ]; then
      if [ "$ipv4_bridge" != "1" ]; then
        nft add rule bridge filter FORWARD oifname "$tap" ether type ip drop 2>/dev/null || true
      fi
      if [ "$ipv6_bridge" != "1" ]; then
        nft add rule bridge filter FORWARD oifname "$tap" ether type ip6 drop 2>/dev/null || true
      fi
    fi
  done

  if [ "$create_bridges" = "1" ]; then
    gateway="$1.1"
    netmask="/24"
    network="$1.0${netmask}"
    dhcp_range="$1.2,$1.255"
    ipv6_prefix="${4:-}"
    ipv6_prefix_length="${5:-}"
    ip addr add "${gateway}${netmask}" broadcast + dev "$2"
    if [ -n "$ipv6_prefix" ] && [ -n "$ipv6_prefix_length" ]; then
      ip -6 addr add "${ipv6_prefix}1/${ipv6_prefix_length}" dev "$2"
    fi
    start_dnsmasq "$2" "$gateway" "$dhcp_range" "$ipv6_prefix" "$ipv6_prefix_length"
    nat_add "$network"
  fi
}

destroy_bridged_interfaces() {
  if [ "$create_bridges" = "1" ]; then
    gateway="$1.1"
    netmask="/24"
    network="$1.0${netmask}"
    ipv6_prefix="${4:-}"
    ipv6_prefix_length="${5:-}"
    nat_del "$network"
    stop_dnsmasq "$2"
    if [ -n "$ipv6_prefix" ] && [ -n "$ipv6_prefix_length" ]; then
      ip -6 addr del "${ipv6_prefix}1/${ipv6_prefix_length}" dev "$2" || true
    fi
    ip addr del "${gateway}${netmask}" dev "$2" || true
  fi
  for i in $(seq ${num_cvd_accounts}); do
    tap="$(printf "$3-%02d" "$i")"
    # Per-tap bridge-filter drops (ebtables replacement) are flushed in
    # bulk in stop() below via `nft flush chain bridge filter FORWARD`,
    # so we do not have to delete them individually here.
    destroy_tap "$tap"
  done
  if [ "$create_bridges" = "1" ]; then
    ip link set dev "$2" down || true
    ip link delete "$2" || true
  fi
}

start() {
  echo 1 > /proc/sys/net/ipv4/ip_forward
  echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

  # Idempotently create the ip cuttlefish + bridge filter topology before
  # any per-interface ops touch the set / chain.
  ensure_nft_topology

  create_bridged_interfaces 192.168.98 "$ethernet_bridge_interface" cvd-etap "${ethernet_ipv6_prefix:-}" "${ethernet_ipv6_prefix_length:-}"

  for i in $(seq ${num_cvd_accounts}); do
    tap="$(printf 'cvd-mtap-%02d' "$i")"
    if [ "$i" -lt 65 ]; then
      create_interface "$tap" 192.168.97 "$i"
    elif [ "$i" -lt 129 ]; then
      create_interface "$tap" 192.168.93 "$((i - 64))"
    fi
  done

  create_bridged_interfaces 192.168.96 "$wifi_bridge_interface" cvd-wtap "${wifi_ipv6_prefix:-}" "${wifi_ipv6_prefix_length:-}"
  for i in $(seq ${num_cvd_accounts}); do
    tap="$(printf 'cvd-wifiap-%02d' "$i")"
    if [ "$i" -lt 65 ]; then
      create_interface "$tap" 192.168.94 "$i"
    elif [ "$i" -lt 129 ]; then
      create_interface "$tap" 192.168.95 "$((i - 64))"
    fi
  done

  if test -f /.dockerenv; then
    chown root:kvm /dev/kvm || true
    chown root:cvdnetwork /dev/vhost-net || true
    chown root:cvdnetwork /dev/vhost-vsock || true
    chmod ug+rw /dev/kvm /dev/vhost-net /dev/vhost-vsock || true
  fi

  command -v nvidia-modprobe >/dev/null 2>&1 && /usr/bin/nvidia-modprobe --modeset || true
}

stop() {
  destroy_bridged_interfaces 192.168.98 "$ethernet_bridge_interface" cvd-etap "${ethernet_ipv6_prefix:-}" "${ethernet_ipv6_prefix_length:-}"

  for i in $(seq ${num_cvd_accounts}); do
    tap="$(printf 'cvd-mtap-%02d' "$i")"
    if [ "$i" -lt 65 ]; then
      destroy_interface "$tap" 192.168.97 "$i"
    elif [ "$i" -lt 129 ]; then
      destroy_interface "$tap" 192.168.93 "$((i - 64))"
    fi
  done

  destroy_bridged_interfaces 192.168.96 "$wifi_bridge_interface" cvd-wtap "${wifi_ipv6_prefix:-}" "${wifi_ipv6_prefix_length:-}"
  for i in $(seq ${num_cvd_accounts}); do
    tap="$(printf 'cvd-wifiap-%02d' "$i")"
    if [ "$i" -lt 65 ]; then
      destroy_interface "$tap" 192.168.94 "$i"
    elif [ "$i" -lt 129 ]; then
      destroy_interface "$tap" 192.168.95 "$((i - 64))"
    fi
  done

  # Flush the bridge filter chain we use as the ebtables replacement so
  # any leftover per-tap drop rules from previous starts don't accumulate
  # across restarts. The `ip cuttlefish` table is left alone because it
  # may still be in use by per-user cvdalloc allocations.
  nft flush chain bridge filter FORWARD 2>/dev/null || true
}

case "${1:-}" in
  start|stop)
    "$1"
    ;;
  restart)
    stop
    start
    ;;
  status)
    ip link show "$ethernet_bridge_interface" >/dev/null 2>&1
    ;;
  *)
    echo "usage: $0 start|stop|restart|status" >&2
    exit 1
    ;;
esac
