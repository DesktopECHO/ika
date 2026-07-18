# Build RPM Packages in Containers

The build container is also compatible with [Podman](https://podman.io).

## Build the image

The build image command must be run at the root of this repository checkout.

Docker versions earlier than 23.0 require
[BuildKit](https://docs.docker.com/build/buildkit/) to build this image.

```bash
docker build \
  --file "tools/buildutils/cw/Containerfile" \
  --tag "android-cuttlefish-build:latest" \
  .
```

## Build the package

The run container command must be run at the root of this repository checkout.

Built RPMs are written under `rpmbuild/RPMS/`.
The container entrypoint builds as the UID/GID that owns the mounted checkout,
so generated files are not left owned by root on the host.

### base

```bash
docker run \
  -e HOST_UID=$(id -u) \
  -e HOST_GID=$(id -g) \
  -v=$PWD:/mnt/build \
  -w /mnt/build \
  android-cuttlefish-build:latest base
```

To persist the Bazel cache across runs:

```bash
mkdir -p out/cuttlefish-bazel
docker run \
  -e HOST_UID=$(id -u) \
  -e HOST_GID=$(id -g) \
  -e CUTTLEFISH_BAZEL_CACHE_ROOT=/mnt/build/out/cuttlefish-bazel \
  -v=$PWD:/mnt/build \
  -w /mnt/build \
  android-cuttlefish-build:latest base
```

### container

```bash
docker run \
  -e HOST_UID=$(id -u) \
  -e HOST_GID=$(id -g) \
  -v=$PWD:/mnt/build \
  -w /mnt/build \
  android-cuttlefish-build:latest container
```

### frontend

```bash
docker run \
  -e HOST_UID=$(id -u) \
  -e HOST_GID=$(id -g) \
  -v=$PWD:/mnt/build \
  -w /mnt/build \
  android-cuttlefish-build:latest frontend
```
