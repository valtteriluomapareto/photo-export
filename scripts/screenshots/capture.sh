#!/usr/bin/env bash
# Release captures using synthetic content. Screen Recording permission is required
# for the shell host; no Accessibility/Automation permission is needed.
# Usage: capture.sh [WIDTHxHEIGHT] [state...] | --list
set -euo pipefail
exec python3 -B "$(dirname "$0")/capture.py" "$@"
