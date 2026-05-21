# podcvd

**Note: Currently `podcvd` is very unstable and it's under development. Please
be aware to use.**

`podcvd` is CLI binary which aims to provide identical interface as `cvd`, but
creating each Cuttlefish instance group on a container instance not to
interfere host environment of each other.

## User setup guide

Execute following commands to register the upstream yum repository containing
the `cuttlefish-podcvd` package on your machine.
```
sudo curl -fsSL https://us-yum.pkg.dev/doc/repo-signing-key.gpg -o /etc/pki/rpm-gpg/RPM-GPG-KEY-android-cuttlefish
sudo tee /etc/yum.repos.d/android-cuttlefish.repo > /dev/null <<'EOF'
[android-cuttlefish]
name=android-cuttlefish
baseurl=https://us-yum.pkg.dev/projects/android-cuttlefish-artifacts/android-cuttlefish-nightly
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-android-cuttlefish
EOF
sudo dnf makecache
```

Execute following commands to install `cuttlefish-podcvd` and set up your
machine from the upstream repository.
```
sudo dnf install cuttlefish-podcvd
/usr/lib/cuttlefish-common/bin/cuttlefish-podcvd-prerequisites.sh
```

Now it's available to execute `podcvd help` or `podcvd create` as you could
execute `cvd help` or `cvd create` after installing `cuttlefish-base` from
upstream or `ika-base` from this fork.

## Development guide

### Manually build podcvd binary

Execute `go build ./cmd/podcvd` from `container/src/podcvd` directory.

### Manually build the podcvd RPM

[tools/buildutils/cw/README.md#container](../../../tools/buildutils/cw/README.md#container)
describes how to build the local `ika-podcvd` RPM.

Execute `sudo dnf install ./ika-podcvd-*.rpm` to install it on your
machine.
