#!/system/bin/sh
# Gives ika_tso.ko the UIDs of the apps that need the TSO memory model on Apple
# CPUs, at boot and whenever /data/system/packages.list changes (an app was
# installed, updated or removed). On other CPUs the module ignores the list.
#
# 3DMark: Sling Shot Extreme livelocks in its lock-free task queue on the Arm
# memory model.
apps="com.futuremark.dmandroid.application"
param=/sys/module/ika_tso/parameters/uids
list=/data/system/packages.list

[ -w "$param" ] || exit 0

update() {
  uids=
  while read -r pkg uid rest; do
    for app in $apps; do
      [ "$pkg" = "$app" ] && uids="${uids:+$uids,}$uid"
    done
  done < "$list"
  # No UID is 4294967295 (an empty list is not accepted).
  echo "${uids:-4294967295}" > "$param"
}

inotifyd - /data/system:wyn | while read -r events file name; do
  [ "$name" = packages.list ] && update
done &
update
wait
