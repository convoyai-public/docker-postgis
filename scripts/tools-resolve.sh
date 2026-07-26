#!/usr/bin/env bash
# Resolve a pinned tool to an executable. Cache first, then PATH.
#
# Usage: tools-resolve.sh <tool>
# Prints the executable path (absolute cache path, or the bare name for PATH
# fallback) to stdout. Exits non-zero if the tool is unavailable.
#
# The pinned cache (`.tools/cache/<host>/<tool>`) is authoritative (CI uses it
# exclusively). On a developer host without the cache, a PATH fallback is
# accepted with a stderr warning so the gate stays runnable via Homebrew installs.
# markdownlint-cli2 is OCI-based and is resolved by the Makefile via `docker run`,
# not by this script.

set -euo pipefail

tool=${1:?usage: tools-resolve.sh <tool>}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="$(scripts/host.sh)"
cache="$root/.tools/cache/$host/$tool"

if [[ -x "$cache" ]]; then
	echo "$cache"
	exit 0
fi
if command -v "$tool" >/dev/null 2>&1; then
	echo "tools-resolve: '$tool' using PATH fallback (run 'make tools' for the pinned cache)" >&2
	echo "$tool"
	exit 0
fi
echo "tools-resolve: '$tool' not found in cache or on PATH. Run 'make tools'." >&2
exit 1
