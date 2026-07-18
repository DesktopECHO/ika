# End-to-End Tests

## Orchestration Tests

The orchestration end-to-end tests require an environment with the `host orchestrator`
service and `cvd` installed.

Run the test command from the `e2etests` directory.

```bash
bazel test --local_test_jobs=1 //orchestration/...
```

### Add a Go Dependency

For example, to add `github.com/gorilla/websocket`:

```bash
go get github.com/gorilla/websocket
```

Add the generated repository name (`com_github_gorilla_websocket` in this
example) to the `use_repo(go_deps, ...)` list in `MODULE.bazel`, then update the
BUILD files:

```bash
bazel run //:gazelle
```
