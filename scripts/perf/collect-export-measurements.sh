#!/bin/bash
set -euo pipefail
exec python3 -B "$(dirname "$0")/collect_export_measurements.py" "$@"
