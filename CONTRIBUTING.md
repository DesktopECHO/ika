# Contributing

This repository is a DesktopECHO fork of `google/android-cuttlefish` with
Fedora/Asahi packaging, the `ika` launcher, ika-scrcpy integration, and the
LineageOS Desktop product layer.

Use normal GitHub pull requests for changes. Keep patches narrowly scoped, and
include the commands you used to validate the change. For changes intended for
upstream Cuttlefish rather than this fork, follow Google's upstream contribution
process and CLA requirements in the upstream repository.

Useful local checks:

```bash
./lineageos/scripts/lib/validate_build_inputs.sh ./lineageos/src
./tools/buildutils/build_packages.sh
```

Some checks require a synced LineageOS workspace or built ROM bundles; mention
when you could not run one.
