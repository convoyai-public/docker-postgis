#!/usr/bin/env bash
# Registry-parity gate: assert the published manifest is byte-identical across
# GAR, Docker Hub, and GHCR.
#
# Usage: publish-parity.sh <tag> <ref-gar> <ref-dh> <ref-ghcr>
#
# Resolves each tag-form ref to its raw manifest via
# `docker buildx imagetools inspect --raw`, then asserts the three raw manifests
# are byte-identical (trailing newlines normalized by $(...)). A mismatch — or a
# failure to resolve any ref — trips the gate (non-zero exit). This is the
# "registry-parity gate" of the WU4 acceptance criteria: the same pushed release
# must resolve to equivalent content in all three registries. Used by
# `make parity TAG=<t> REF_GAR=<r> REF_DH=<r> REF_GHCR=<r>` (GNUmakefile).
#
# Why raw-byte comparison: the manifest digest IS sha256 of the raw manifest, so
# byte-identical raw manifests imply identical digests. Comparing the raw bytes
# directly is version-independent (no dependence on buildx Go-template field
# names) and fails closed (any resolution failure or content drift is fatal).

set -euo pipefail

tag=${1:?usage: publish-parity.sh <tag> <ref-gar> <ref-dh> <ref-ghcr>}
gar=${2:?usage: publish-parity.sh <tag> <ref-gar> <ref-dh> <ref-ghcr>}
dh=${3:?usage: publish-parity.sh <tag> <ref-gar> <ref-dh> <ref-ghcr>}
ghcr=${4:?usage: publish-parity.sh <tag> <ref-gar> <ref-dh> <ref-ghcr>}

# Fetch the raw manifest for a tag-form ref. Fails the gate if resolution errors.
raw_manifest() {
	local ref=$1 label=$2 raw
	if ! raw=$(docker buildx imagetools inspect --raw "$ref" 2>/dev/null); then
		echo "[publish-parity] FAIL: could not resolve manifest for ${label} (${ref})" >&2
		return 1
	fi
	if [[ -z "$raw" ]]; then
		echo "[publish-parity] FAIL: ${label} (${ref}) resolved to an empty manifest" >&2
		return 1
	fi
	printf '%s' "$raw"
}

echo "[publish-parity] CHECK tag=${tag}"
raw_gar=$(raw_manifest "$gar" GAR) || exit 1
raw_dh=$(raw_manifest "$dh" "Docker Hub") || exit 1
raw_ghcr=$(raw_manifest "$ghcr" GHCR) || exit 1

bytes_gar=$(printf '%s' "$raw_gar" | wc -c | tr -d ' ')
bytes_dh=$(printf '%s' "$raw_dh" | wc -c | tr -d ' ')
bytes_ghcr=$(printf '%s' "$raw_ghcr" | wc -c | tr -d ' ')
echo "[publish-parity] GAR        manifest=${bytes_gar} bytes"
echo "[publish-parity] Docker Hub manifest=${bytes_dh} bytes"
echo "[publish-parity] GHCR       manifest=${bytes_ghcr} bytes"

if [[ "$raw_gar" == "$raw_dh" && "$raw_gar" == "$raw_ghcr" ]]; then
	echo "[publish-parity] PASS (byte-identical manifest across GAR + Docker Hub + GHCR)"
else
	echo "[publish-parity] FAIL: manifests differ across registries" >&2
	exit 1
fi
