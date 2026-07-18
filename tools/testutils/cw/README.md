# Run End-to-End Tests in Containers

## Set the relevant permissions

> [!IMPORTANT]
> Use rootless Podman for development; do not use rootful Podman.

GitHub Actions does not provide a Fedora-based runner. Podman provides a
Fedora-based container that more closely matches host behavior.

```bash
sudo setfacl -m "u:$(whoami):rw" /dev/kvm
sudo setfacl -m "u:$(whoami):rw" /dev/vhost-net
sudo setfacl -m "u:$(whoami):rw" /dev/vhost-vsock
```

## Build the image

Run the image-build command from the root of the Ika repository.

Image creation expects ika RPM packages: `ika-base-*.rpm`,
`ika-metrics-*.rpm`, `ika-user-*.rpm`, and `ika-orchestration-*.rpm` in the
current directory.

```bash
podman build \
  --file "tools/testutils/cw/Containerfile" \
  --tag "android-cuttlefish-e2etest:latest" \
  .
```

## Run the container

Run the container command from the root of the Ika repository.

```bash
mkdir -p /tmp/cw_bazel && \
podman run --name tester \
  -d \
  --pids-limit=8192 \
  -v /tmp/cw_bazel:/tmp/cw_bazel \
  -v .:/src/workspace \
  -w /src/workspace/e2etests \
  --cap-add=NET_ADMIN \
  --device=/dev/kvm:/dev/kvm:rwm \
  --device=/dev/net/tun:/dev/net/tun:rwm \
  --device=/dev/vhost-net:/dev/vhost-net:rwm \
  --device=/dev/vhost-vsock:/dev/vhost-vsock:rwm \
  android-cuttlefish-e2etest:latest
```

## Run the test

```bash
podman exec -it tester \
  bazel --output_user_root=/tmp/cw_bazel/output test //orchestration/journal_gatewayd_test:journal_gatewayd_test_test
```
