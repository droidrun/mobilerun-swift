#!/bin/sh
# Copyright 2026 Mobilerun
# SPDX-License-Identifier: Apache-2.0
set -eu
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 TAG CONFORMANCE_CLONE" >&2
    exit 2
fi
tag=$1
clone=$2
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
git -C "$clone" fetch --tags
git -C "$clone" rev-parse --verify "refs/tags/$tag^{commit}" >/dev/null
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
git -C "$clone" archive "refs/tags/$tag" fixtures > "$stage/fixtures.tar"
tar -xf "$stage/fixtures.tar" -C "$stage"
rm -rf "$root/conformance/fixtures"
mv "$stage/fixtures" "$root/conformance/fixtures"
printf '%s\n' "$tag" > "$root/conformance/VERSION"
