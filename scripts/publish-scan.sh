#!/usr/bin/env bash
# Grype vulnerability scan with a checked-in policy gate (WU4 publish pipeline).
#
# Usage: publish-scan.sh <image-ref> <policy-config>
#
# Scans the digest-pinned image ref against the grype configuration file (which
# carries the fail-on-severity threshold and the documented ignore accept-list).
# Exits non-zero when the policy gate trips — a vulnerability at or above the
# configured severity that is not on the ignore list — and the publish workflow
# fails the job before signing/parity. This is the "scan-policy gate" of the WU4
# acceptance criteria. Used by `make scan IMAGE=<ref>` (GNUmakefile).
#
# grype has no --policy flag; the gate is the config file's `fail-on-severity` +
# `ignore` keys, applied via `-c`. See .grype/policy.yaml for the policy contract.
#
# The grype binary is resolved by the caller (Make) via scripts/tools-resolve.sh
# and exported here as $GRYPE, so the pinned cache version is authoritative in CI.

set -euo pipefail

image=${1:?usage: publish-scan.sh <image-ref> <policy-config>}
policy=${2:?usage: publish-scan.sh <image-ref> <policy-config>}

GRYPE="${GRYPE:-grype}"
[[ -x "$GRYPE" ]] || {
	echo "publish-scan: grype not found at '$GRYPE' (run 'make tools')" >&2
	exit 2
}
[[ -f "$policy" ]] || {
	echo "publish-scan: policy config '$policy' not found" >&2
	exit 2
}

echo "[publish-scan] SCAN image=${image} policy=${policy}"
# -c applies the policy config (fail-on-severity + ignore accept-list). grype
# exits non-zero on a gating vulnerability; set -e propagates it to the job.
"$GRYPE" "$image" -c "$policy" -o table
echo "[publish-scan] PASS (no policy-gating vulnerabilities at or above the configured severity)"
