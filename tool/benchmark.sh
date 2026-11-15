#!/bin/sh
# Copyright 2026 Mobilerun
# SPDX-License-Identifier: Apache-2.0
# Run this entry under your host's exclusive simulator/build lock.
set -eu
cd "$(dirname "$0")/.."
exec python3 tool/benchmark.py "$@"
