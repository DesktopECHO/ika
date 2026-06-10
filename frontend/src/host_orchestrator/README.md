# Host Orchestrator

## API Documentation

The Host Orchestrator API documentation is generated with the [swag](https://github.com/swaggo/swag) tool,
generating OpenAPI Specifications based on Go annotations.

The generated OpenAPI document is [docs/swagger.yaml](docs/swagger.yaml).
Use that local file with Swagger UI or another OpenAPI viewer when reviewing
changes in this fork.

## Update documentation 

Install `swag`:

```
go install github.com/swaggo/swag/cmd/swag@latest
```

Generate updated documentation:

```
# run in `frontend/src/host_orchestrator` from this checkout
$(go env GOPATH)/bin/swag init --outputTypes yaml
```
