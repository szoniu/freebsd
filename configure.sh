#!/usr/bin/env bash
# configure.sh — Wrapper: runs only the TUI configuration wizard
# Generates a config file without performing any installation steps.
#
# Usage:
#   ./configure.sh                    — Run wizard, save to default location
#   ./configure.sh --config my.conf   — Run wizard, save to specified file
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/install.sh" --configure "$@"
