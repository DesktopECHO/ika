# e2e Tests

## Orchestration tests

The orchestration e2e tests require an environment with the `host orchestrator`
service and `cvd` installed.

Run the test command from the `e2etests` directory.

```bash
bazel test --local_test_jobs=1 //orchestration/...
```

### Adding a new Go dependency

If adding `github.com/gorilla/websocket`:

```bash
bazel run //:gazelle -- update-repos -to_macro=go_repositories.bzl%repos "github.com/gorilla/websocket"
```

```bash
bazel run //:gazelle
```
