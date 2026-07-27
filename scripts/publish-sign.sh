#!/usr/bin/env bash
# Cosign keyless sign + CycloneDX SBOM attest of one published image ref.
#
# Usage: publish-sign.sh <image-ref> <sbom-path>
#
# Keyless (OIDC) signing: cosign signs the digest-pinned ref using the GitHub
# Actions OIDC token, then attests the CycloneDX SBOM as a cosign attestation.
# Both use --yes (non-interactive transparency-log consent). Keyless is the
# default in cosign v3 (no COSIGN_EXPERIMENTAL needed); cosign auto-detects the
# GitHub OIDC endpoint from the runner when the job carries `id-token: write`.
#
# The publish workflow invokes this once PER REGISTRY ref (3x: GAR, Docker Hub,
# GHCR) so each registry's digest carries its own signature + SBOM attestation.
# Used by `make sign REF=<ref> SBOM=<path>` (GNUmakefile).
#
# The cosign binary is resolved by the caller (Make) via scripts/tools-resolve.sh
# and exported here as $COSIGN, so the pinned cache version is authoritative in CI.

set -euo pipefail

ref=${1:?usage: publish-sign.sh <image-ref> <sbom-path>}
sbom=${2:?usage: publish-sign.sh <image-ref> <sbom-path>}

COSIGN="${COSIGN:-cosign}"
[[ -x "$COSIGN" ]] || {
	echo "publish-sign: cosign not found at '$COSIGN' (run 'make tools')" >&2
	exit 2
}
[[ -f "$sbom" ]] || {
	echo "publish-sign: sbom '$sbom' not found" >&2
	exit 2
}

# A digest-pinned ref (repo@sha256:...) is the canonical cosign signing target;
# signing a floating tag is discouraged. The publish workflow passes exactly that.
echo "[publish-sign] SIGN ref=${ref}"
"$COSIGN" sign --yes "$ref"

echo "[publish-sign] ATTEST predicate=${sbom} type=cyclonedx ref=${ref}"
"$COSIGN" attest --yes --predicate "$sbom" --type cyclonedx "$ref"

echo "[publish-sign] DONE ref=${ref}"
