#!/usr/bin/env bash
# Syft CycloneDX SBOM generation for the published image (WU4 publish pipeline).
#
# Usage: publish-sbom.sh <image-ref> <output-path>
#
# Generates a CycloneDX JSON SBOM for the digest-pinned image ref and writes it
# to <output-path>. The publish workflow retains the SBOM as a workflow artifact
# and feeds it to the cosign attest gate (publish-sign.sh). CycloneDX is the
# format the cosign attest --type cyclonedx predicate consumes. Used by
# `make sbom IMAGE=<ref> OUTPUT=<path>` (GNUmakefile).
#
# The syft binary is resolved by the caller (Make) via scripts/tools-resolve.sh
# and exported here as $SYFT, so the pinned cache version is authoritative in CI.
#
# Note: syft scans the image's default platform (amd64 on the ubuntu-24.04
# runner). A per-arch SBOM is a future refinement; WU4 ships a single SBOM, per
# the plan's "produces Syft CycloneDX SBOM" acceptance criterion.

set -euo pipefail

image=${1:?usage: publish-sbom.sh <image-ref> <output-path>}
output=${2:?usage: publish-sbom.sh <image-ref> <output-path>}

SYFT="${SYFT:-syft}"
[[ -x "$SYFT" ]] || {
	echo "publish-sbom: syft not found at '$SYFT' (run 'make tools')" >&2
	exit 2
}

echo "[publish-sbom] GENERATE image=${image} format=cyclonedx-json -> ${output}"
# Redirect stdout: syft writes the report to stdout, progress to stderr. This
# form is stable across syft versions (no --file dependency).
"$SYFT" "$image" -o cyclonedx-json >"$output"
echo "[publish-sbom] WROTE $(wc -c <"$output" | tr -d ' ') bytes -> ${output}"
