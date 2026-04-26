#!/usr/bin/env bash

set -euo pipefail

if [ -f /etc/sysconfig/cuttlefish-podcvd ]; then
  . /etc/sysconfig/cuttlefish-podcvd
fi

podcvd_cidr=${podcvd_cidr:-192.168.80.0/24}
podcvd_ifname=podcvd

start() {
  ip link add "${podcvd_ifname}" type dummy
  ip link set "${podcvd_ifname}" up
  ip route add local "${podcvd_cidr}" dev "${podcvd_ifname}"
}

stop() {
  for cidr in $(ip route show table local dev "${podcvd_ifname}" | awk '{print $2}'); do
    ip route del local "${cidr}" dev "${podcvd_ifname}" || true
  done
  ip link set dev "${podcvd_ifname}" down || true
  ip link del "${podcvd_ifname}" || true
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
    ip link show "${podcvd_ifname}" >/dev/null 2>&1
    ;;
  *)
    echo "usage: $0 start|stop|restart|status" >&2
    exit 1
    ;;
esac