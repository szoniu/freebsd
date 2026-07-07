#!/usr/bin/env bash
# tests/shellcheck.sh — Run shellcheck on all project .sh files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v shellcheck &>/dev/null; then
    echo "ERROR: shellcheck not found. Install it with: brew install shellcheck (or xbps-install -S shellcheck)" >&2
    exit 1
fi

echo "=== ShellCheck Lint ==="
echo "Scanning: ${SCRIPT_DIR}"

errors=0
files=0

while IFS= read -r -d '' file; do
    (( files++ )) || true
    # Lint POSIX /bin/sh scripts as sh so bashisms are caught — e.g.
    # tests/live-hw-check.sh runs on the bare live medium WITHOUT bash.
    shell="bash"
    case "$(head -n 1 "${file}")" in
        '#!/bin/sh'*) shell="sh" ;;
    esac
    if ! shellcheck --shell="${shell}" --severity=warning \
         --exclude=SC1091,SC2034,SC2154,SC1090,SC2155 \
         "${file}"; then
        (( errors++ )) || true
        echo "FAIL: ${file}"
    fi
done < <(find "${SCRIPT_DIR}" -name '*.sh' -not -path '*/\.*' -print0)

echo ""
echo "=== Results ==="
echo "Files checked: ${files}"
echo "Files with issues: ${errors}"

if [[ ${errors} -gt 0 ]]; then
    echo "FAILED: ${errors} file(s) have shellcheck warnings"
    exit 1
else
    echo "PASSED: All files clean"
    exit 0
fi
