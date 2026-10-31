# Create a GCE Image for Cuttlefish Orchestration

## Setup

```bash
cd tools/baseimage
gcloud auth application-default login
```

## Step 1: Create an Image with the Desired Kernel Version

Skip to step 2 if you already have an image with the desired kernel.

```bash
go run ./cmd/create_gce_fixed_kernel \
  -project <project> \
  -source-image-project fedora-cloud \
  -source-image <fedora_cloud_image_name> \
  -kernel-package kernel-<version> \
  -image-name <fixed_kernel_image_name>
```

## Step 2: Create a Base Image

Skip to step 3 if you already have a base image.

```bash
go run ./cmd/create_gce_base_image \
  -project <project> \
  -source-image-project <project> \
  -source-image <fixed_kernel_image_name> \
  -image-name <base_image_name>
```

## Step 3: Create an Image with Ika RPM Packages

Run these `go run ./cmd/...` commands from the `tools/baseimage` directory.

```bash
go run ./cmd/gce_install_cuttlefish_packages \
  -project <project> \
  -source-image-project <project> \
  -source-image <base_image_name> \
  -image-name <output_image_name> \
  -rpm <path/to/ika-base-rpm> \
  -rpm <path/to/ika-user-rpm> \
  -rpm <path/to/ika-orchestration-rpm>
```

## Step 4: Validate the Output Image

```bash
go run ./cmd/gce_validate_image \
  -project <project> \
  -image-project <project> \
  -image <output_image_name>
```
