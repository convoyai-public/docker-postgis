#!/usr/bin/env bash
# Populate the pinned tool cache for one tool (current host) from tools.yaml.
#
# Usage: tools-sync.sh <tool>
#
# Downloads the artifact for the current host, verifies the recorded SHA-256
# checksum, and installs the executable (or preloads the OCI image for
# kind: oci tools) under `.tools/cache/<host>/<tool>`. The cache is gitignored.
# `make tools` calls this once per tool.

set -euo pipefail

tool=${1:?usage: tools-sync.sh <tool>}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mg="$root/scripts/manifest-get.sh"
host="$(scripts/host.sh)"
cache_dir="$root/.tools/cache/$host"
mkdir -p "$cache_dir"

# sha256 verifier portable across macOS (shasum) and Linux (sha256sum).
sha_verify() {
	local expected="$1" file="$2"
	local sum
	if command -v sha256sum >/dev/null 2>&1; then
		sum=$(sha256sum "$file" | awk '{print $1}')
	else
		sum=$(shasum -a 256 "$file" | awk '{print $1}')
	fi
	[[ "$sum" == "$expected" ]] || {
		echo "tools-sync: checksum mismatch for $file" >&2
		echo "  expected: $expected" >&2
		echo "  got:      $sum" >&2
		return 1
	}
}

kind=$("$mg" "$tool" kind)
if [[ "$kind" == "oci" ]]; then
	image=$("$mg" "$tool" image)
	echo "tools-sync: preloading OCI image for $tool: $image"
	docker image pull "$image" >/dev/null
	touch "$cache_dir/$tool.marker"
	echo "$tool: oci image preloaded"
	exit 0
fi

url=$("$mg" "$tool" url "$host")
sha=$("$mg" "$tool" sha256 "$host")
archive=$("$mg" "$tool" archive "$host")
path=$("$mg" "$tool" path "$host")

[[ -n "$url" && -n "$sha" && -n "$archive" && -n "$path" ]] || {
	echo "tools-sync: incomplete manifest entry for $tool ($host)" >&2
	exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

case "$archive" in
tar.gz | tgz)
	curl -fsSL "$url" -o "$tmp/pkg"
	sha_verify "$sha" "$tmp/pkg"
	mkdir -p "$tmp/x"
	tar -xzf "$tmp/pkg" -C "$tmp/x"
	install -m 0755 "$tmp/x/$path" "$cache_dir/$tool"
	;;
bin)
	curl -fsSL "$url" -o "$tmp/$tool"
	sha_verify "$sha" "$tmp/$tool"
	install -m 0755 "$tmp/$tool" "$cache_dir/$tool"
	;;
*)
	echo "tools-sync: unknown archive format '$archive' for $tool" >&2
	exit 1
	;;
esac

echo "$tool: installed $cache_dir/$tool"
