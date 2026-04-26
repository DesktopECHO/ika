# Create a GCE image for orchestrating Cuttlefish instances

## Setup

```
cd tools/baseimage
gcloud auth application-default login
```

## Step 1. Create image with wanted kernel version

Go to Step 2 if you have already an image with the wanted kernel.

```
go run ./cmd/create_gce_fixed_kernel \
  -project <project> \
  -source-image-project fedora-cloud \
  -source-image <fedora_cloud_image_name> \
  -kernel-package kernel-<version> \
  -image-name <fixed_kernel_image_name>
```

## Step 2. Create base image

Go to Step 3 if you have already a base image.

```
go run ./cmd/create_gce_base_image \
  -project <project> \
  -source-image-project <project> \
  -source-image <fixed_kernel_image_name> \
  -image-name <base_image_name>
```

## Step 3. Create image with cuttlefish RPM packages installed.

Run these `go run ./cmd/...` commands from the `tools/baseimage` directory.

```
go run ./cmd/gce_install_cuttlefish_packages \
  -project <project> \
  -source-image-project <project> \
  -source-image <base_image_name> \
  -image-name <output_image_name> \
  -rpm <path/to/cuttlefish-base-rpm> \
  -rpm <path/to/cuttlefish-user-rpm> \
  -rpm <path/to/cuttlefish-orchestration-rpm>
```

## Step 4. Validate output image

```
go run ./cmd/gce_validate_image \
  -project <project> \
  -image-project <project> \
  -image <output_image_name>
```
