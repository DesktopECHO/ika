#!/bin/bash

set -e

# should update tags before do anything
echo "step 1: write version information"
CHANGELOG=$(mktemp)
version=$(tr -d '\n' < ../packaging/VERSION)
distribution=fedora
changes="Version: ${version}
Distribution: ${distribution}"
echo "" >> "${CHANGELOG}"
echo "$changes" >> "${CHANGELOG}"

# update changelog and descriptions
echo "step 2: update changelog and descriptions in release"
CREATE_DATE=$(date)
echo "Image was created at ${CREATE_DATE}" >> "${CHANGELOG}"

mv "${CHANGELOG}" usr/share/version_info

