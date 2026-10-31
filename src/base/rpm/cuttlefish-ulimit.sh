#!/usr/bin/env bash

set +e

target_nofile=524288
target_rtprio=10

if ! id -nG 2>/dev/null | grep -qw cvdnetwork; then
  return 0 2>/dev/null || exit 0
fi

current_soft="$(ulimit -Sn 2>/dev/null)"
current_hard="$(ulimit -Hn 2>/dev/null)"
current_soft_rtprio="$(ulimit -Sr 2>/dev/null)"
current_hard_rtprio="$(ulimit -Hr 2>/dev/null)"

case "${current_soft}" in
  unlimited) current_soft="${target_nofile}" ;;
esac
case "${current_hard}" in
  unlimited) current_hard="${target_nofile}" ;;
esac
case "${current_soft_rtprio}" in
  unlimited) current_soft_rtprio="${target_rtprio}" ;;
esac
case "${current_hard_rtprio}" in
  unlimited) current_hard_rtprio="${target_rtprio}" ;;
esac

if [ "${current_hard:-0}" -ge "${target_nofile}" ] &&
   [ "${current_soft:-0}" -lt "${target_nofile}" ]; then
  ulimit -Sn "${target_nofile}" >/dev/null 2>&1 || true
fi

if [ "${current_hard_rtprio:-0}" -ge "${target_rtprio}" ] &&
   [ "${current_soft_rtprio:-0}" -lt "${target_rtprio}" ]; then
  ulimit -Sr "${target_rtprio}" >/dev/null 2>&1 || true
fi
