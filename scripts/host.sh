#!/usr/bin/env bash
# Print the repository's canonical host triple for tool resolution:
#   darwin/arm64 | linux/amd64 | linux/arm64
# Used by tools-sync.sh / tools-resolve.sh to pick the manifest artifact.
# Exits non-zero on an unsupported host (per TOOLSPEC: darwin/amd64 unsupported).

set -euo pipefail

os=$(uname -s)
mach=$(uname -m)
case "$os" in
Darwin) os=darwin ;;
Linux) os=linux ;;
*)
	echo "host: unsupported OS '$os'" >&2
	exit 1
	;;
esac
case "$mach" in
arm64 | aarch64) arch=arm64 ;;
x86_64 | amd64) arch=amd64 ;;
*)
	echo "host: unsupported arch '$mach'" >&2
	exit 1
	;;
esac
echo "${os}/${arch}"
