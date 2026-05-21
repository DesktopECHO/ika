# Build RPM packages in containers

**Podman Compatible**: packages can be built with [Podman](https://podman.io) as well.

## Build the image

The build image command must be run at the root of this repository checkout.

Enabling Docker [BuildKit](https://docs.docker.com/build/buildkit/) is required
on Docker version below 23.0 to build this image.

```
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

```
docker run \
  -e HOST_UID=$(id -u) \
  -e HOST_GID=$(id -g) \
  -v=$PWD:/mnt/build \
  -w /mnt/build \
  android-cuttlefish-build:latest base
```

Persist bazel cache among executions.

```
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

```
docker run \
  -e HOST_UID=$(id -u) \
  -e HOST_GID=$(id -g) \
  -v=$PWD:/mnt/build \
  -w /mnt/build \
  android-cuttlefish-build:latest container
```

### frontend

```
docker run \
  -e HOST_UID=$(id -u) \
  -e HOST_GID=$(id -g) \
  -v=$PWD:/mnt/build \
  -w /mnt/build \
  android-cuttlefish-build:latest frontend
```
