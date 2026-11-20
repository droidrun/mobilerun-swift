#!/usr/bin/env bash
# Copyright 2026 Mobilerun
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
exec python3 "$(dirname "$0")/run-sample.py" "$@"
