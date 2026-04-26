# Run e2e tests in Containers

## Podman rootfull containers

**IMPORTANT** Do not use rootfull podman in your development workflow, use rootless podman.

Github Actions does not offer a Fedora based runner, using Podman we can create Fedora based
containers that mimics a real host behavior.


## Build the image

The build image command must be run at the root of the `android-cuttlefish` repo directory.

Image creation expects cuttlefish RPM packages: `cuttlefish-base-*.rpm`,
`cuttlefish-user-*.rpm` and `cuttlefish-orchestration-*.rpm` in the
current directory.

```
sudo podman build \
  --file "tools/testutils/cw/Containerfile" \
  --tag "android-cuttlefish-e2etest:latest" \
  .
```


## Run the container
The run container command must be run at the root of the `android-cuttlefish` repo directory.

```
mkdir -p -m 777 /tmp/cw_bazel && \
sudo podman run \
  --name tester \
  -d \
  --privileged \
  --pids-limit=8192 \
  -v /tmp/cw_bazel:/tmp/cw_bazel \
  -v .:/src/workspace \
  -w /src/workspace/e2etests \
  android-cuttlefish-e2etest:latest
```

## Run the test

```
sudo podman exec \
  --user=testrunner \
  -it tester \
  bazel --output_user_root=/tmp/cw_bazel/output test //orchestration/journal_gatewayd_test:journal_gatewayd_test_test
```
