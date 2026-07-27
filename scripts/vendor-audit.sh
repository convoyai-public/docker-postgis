#!/usr/bin/env bash
# Report upstream commits not yet merged into convoy-vendor.
#
# Prints the commits reachable from upstream/master but not from convoy-vendor.
# Exits 0 with an "in sync" message when there are none. This is a reporting
# backstop only: synchronization remains a reviewed manual merge (see
# CONVOY-FORK.md). It never rewrites branches or publishes.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! git -C "$root" rev-parse --verify --quiet upstream/master >/dev/null; then
	echo "vendor-audit: 'upstream/master' ref not found. Run: git fetch upstream" >&2
	exit 2
fi
if ! git -C "$root" rev-parse --verify --quiet convoy-vendor >/dev/null; then
	echo "vendor-audit: 'convoy-vendor' ref not found." >&2
	exit 2
fi

newcommits=$(git -C "$root" log --oneline convoy-vendor..upstream/master || true)

if [[ -z "$newcommits" ]]; then
	echo "vendor-audit: convoy-vendor is in sync with upstream/master."
	exit 0
fi

count=$(printf '%s\n' "$newcommits" | grep -c .)
echo "vendor-audit: $count upstream commit(s) not yet on convoy-vendor:"
echo
echo "$newcommits"
echo
echo "vendor-audit: synchronization is a reviewed manual merge. See CONVOY-FORK.md."
exit 0
