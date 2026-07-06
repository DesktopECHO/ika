#!/usr/bin/env bash

set -euo pipefail

# Cuttlefish host resource setup. The ika workflow uses per-user cvdalloc
# networking, so this service does not set up any system-wide bridge/NAT/dnsmasq
# networking. Its job is host setup that must run once per boot -- currently
# raising the udmabuf caps the gfxstream Vulkan host-visible path needs (the
# sysfs params reset to kernel defaults on every boot, so a one-shot won't stick).

modprobe udmabuf 2>/dev/null || true

if [ -f /etc/sysconfig/cuttlefish-host-resources ]; then
  . /etc/sysconfig/cuttlefish-host-resources
fi

udmabuf_list_limit=${udmabuf_list_limit:-8192}
udmabuf_size_limit_mb=${udmabuf_size_limit_mb:-256}

tune_udmabuf() {
  if [ -w /sys/module/udmabuf/parameters/list_limit ]; then
    echo "$udmabuf_list_limit" > /sys/module/udmabuf/parameters/list_limit || true
  fi
  if [ -w /sys/module/udmabuf/parameters/size_limit_mb ]; then
    echo "$udmabuf_size_limit_mb" > /sys/module/udmabuf/parameters/size_limit_mb || true
  fi
}

start() {
  tune_udmabuf

  if test -f /.dockerenv; then
    chown root:kvm /dev/kvm || true
    chown root:cvdnetwork /dev/vhost-net || true
    chown root:cvdnetwork /dev/vhost-vsock || true
    chmod ug+rw /dev/kvm /dev/vhost-net /dev/vhost-vsock || true
  fi

  command -v nvidia-modprobe >/dev/null 2>&1 && /usr/bin/nvidia-modprobe --modeset || true
}

stop() {
  :
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
    [ -r /sys/module/udmabuf/parameters/size_limit_mb ]
    ;;
  *)
    echo "usage: $0 start|stop|restart|status" >&2
    exit 1
    ;;
esac
