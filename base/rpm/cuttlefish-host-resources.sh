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

ebtables=$(command -v ebtables-nft || command -v ebtables || echo "")
iptables=$(command -v iptables-nft || command -v iptables)
nmcli=$(command -v nmcli || true)

# On modern Fedora/Asahi, ebtables may not be installed.  When the variable is
# empty the bridged-interface code paths that need it will use nft(8) instead.
use_nft_ebtables=0
if [ -z "${ebtables}" ]; then
  if command -v nft >/dev/null 2>&1; then
    use_nft_ebtables=1
  fi
fi

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
  "$iptables" -t nat -A POSTROUTING -s "$network" -j MASQUERADE
}

destroy_interface() {
  local tap="$1"
  local gateway="$2.$((4*$3 - 3))"
  local netmask="/30"
  local network="$2.$((4*$3 - 4))${netmask}"
  local ipv6_prefix="${4:-}"
  local ipv6_prefix_length="${5:-}"

  "$iptables" -t nat -D POSTROUTING -s "$network" -j MASQUERADE || true
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
        if [ -n "${ebtables}" ]; then
          "$ebtables" -t broute -A BROUTING -p ipv4 --in-if "$tap" -j DROP
          "$ebtables" -t filter -A FORWARD -p ipv4 --out-if "$tap" -j DROP
        elif [ "$use_nft_ebtables" = "1" ]; then
          nft add rule bridge filter FORWARD oifname "$tap" ether type ip drop 2>/dev/null || true
        fi
      fi
      if [ "$ipv6_bridge" != "1" ]; then
        if [ -n "${ebtables}" ]; then
          "$ebtables" -t broute -A BROUTING -p ipv6 --in-if "$tap" -j DROP
          "$ebtables" -t filter -A FORWARD -p ipv6 --out-if "$tap" -j DROP
        elif [ "$use_nft_ebtables" = "1" ]; then
          nft add rule bridge filter FORWARD oifname "$tap" ether type ip6 drop 2>/dev/null || true
        fi
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
    "$iptables" -t nat -A POSTROUTING -s "$network" -j MASQUERADE
  fi
}

destroy_bridged_interfaces() {
  if [ "$create_bridges" = "1" ]; then
    gateway="$1.1"
    netmask="/24"
    network="$1.0${netmask}"
    ipv6_prefix="${4:-}"
    ipv6_prefix_length="${5:-}"
    "$iptables" -t nat -D POSTROUTING -s "$network" -j MASQUERADE || true
    stop_dnsmasq "$2"
    if [ -n "$ipv6_prefix" ] && [ -n "$ipv6_prefix_length" ]; then
      ip -6 addr del "${ipv6_prefix}1/${ipv6_prefix_length}" dev "$2" || true
    fi
    ip addr del "${gateway}${netmask}" dev "$2" || true
  fi
  for i in $(seq ${num_cvd_accounts}); do
    tap="$(printf "$3-%02d" "$i")"
    if [ "$create_bridges" != "1" ]; then
      if [ "$ipv4_bridge" != "1" ]; then
        if [ -n "${ebtables}" ]; then
          "$ebtables" -t filter -D FORWARD -p ipv4 --out-if "$tap" -j DROP || true
          "$ebtables" -t broute -D BROUTING -p ipv4 --in-if "$tap" -j DROP || true
        fi
      fi
      if [ "$ipv6_bridge" != "1" ]; then
        if [ -n "${ebtables}" ]; then
          "$ebtables" -t filter -D FORWARD -p ipv6 --out-if "$tap" -j DROP || true
          "$ebtables" -t broute -D BROUTING -p ipv6 --in-if "$tap" -j DROP || true
        fi
      fi
    fi
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

  # Ensure the nft bridge table exists when using nft for ebtables replacements
  if [ "$use_nft_ebtables" = "1" ]; then
    nft add table bridge filter 2>/dev/null || true
    nft add chain bridge filter FORWARD '{ type filter hook forward priority 0; }' 2>/dev/null || true
  fi

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

  # Clean up nft bridge rules if we created them
  if [ "$use_nft_ebtables" = "1" ]; then
    nft flush chain bridge filter FORWARD 2>/dev/null || true
  fi
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
