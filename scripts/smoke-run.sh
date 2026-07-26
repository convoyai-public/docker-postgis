#!/usr/bin/env bash
# Runnable per-architecture container smoke for the 18-3.6 PostGIS image.
#
# Usage: smoke-run.sh <arm64|amd64> [context-dir]
#
# Builds the image for the target arch as a loadable single-arch image, starts a
# detached Postgres container, waits for it to accept connections, then asserts:
#   - CREATE EXTENSION IF NOT EXISTS postgis succeeds
#   - postgis_full_version() reports a non-empty POSTGIS= string
#   - a basic spatial op (ST_Distance on two geometry points) returns 5
# Structured [smoke-<arch>] markers go to stdout; failures go to stderr with a
# non-zero exit. The container is removed on any exit (trap). This script is the
# executable verification of the WU2 acceptance criteria: the built image is
# RUNNABLE on each arch, not merely buildable.
#
# Thin Convoy helper (CONVOY-FORK.md). No publish/registry logic (that is WU4).
# Buildx is a TOOLSPEC host prerequisite; this script adds no new toolchain.

set -euo pipefail

arch=${1:?usage: smoke-run.sh <arm64|amd64> [context-dir]}
case "$arch" in
arm64 | amd64) ;;
*)
	echo "smoke: invalid arch '$arch' (expected arm64|amd64)" >&2
	exit 2
	;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
context=${2:-$root/18-3.6}
version=18-3.6
tag="convoy-postgres:${version}-smoke-${arch}"
container="convoy-postgres-smoke-${arch}-$$"

rel=${context#"$root/"}

echo "[smoke-${arch}] START platform=linux/${arch} image=${tag} context=${rel}"

# Build a loadable single-arch image. --load requires exactly one --platform.
echo "[smoke-${arch}] BUILD (buildx --load; amd64 is emulated on Apple Silicon)"
docker buildx build --platform "linux/${arch}" --load -t "$tag" "$context"

cleanup() {
	if [[ -n "${container:-}" ]]; then
		docker rm -f "$container" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

echo "[smoke-${arch}] RUN container=${container}"
docker run -d --name "$container" --platform "linux/${arch}" \
	-e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=postgres \
	"$tag" >/dev/null

# Wait for Postgres to accept connections. 120s is generous for amd64 emulation.
echo "[smoke-${arch}] WAIT readiness (pg_isready)"
deadline=$((SECONDS + 120))
until docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; do
	if ((SECONDS >= deadline)); then
		echo "[smoke-${arch}] FAIL: Postgres not ready within 120s" >&2
		docker logs "$container" >&2 2>&1 || true
		exit 1
	fi
	sleep 1
done
echo "[smoke-${arch}] READY"

psql() { docker exec "$container" psql -U postgres -d postgres -tAc "$@"; }

# Assertion 1: CREATE EXTENSION succeeds (set -e makes non-zero fatal). IF NOT
# EXISTS keeps it idempotent even though initdb-postgis.sh already loads postgis
# during init.
psql "CREATE EXTENSION IF NOT EXISTS postgis;" >/dev/null
echo "[smoke-${arch}] CREATE EXTENSION postgis: ok"

# Assertion 2: postgis_full_version() reports a non-empty POSTGIS= string.
pgver=$(psql "SELECT postgis_full_version();")
if [[ -z "$pgver" || ! "$pgver" =~ POSTGIS= ]]; then
	echo "[smoke-${arch}] FAIL: postgis_full_version() unexpected: '${pgver:-<empty>}'" >&2
	exit 1
fi
# Report the first line (the POSTGIS="x.y.z ..." headline); the full string is long.
echo "[smoke-${arch}] postgis_full_version: ${pgver%%$'\n'*}"

# Assertion 3: a basic spatial operation returns the geometric distance (3-4-5).
dist=$(psql "SELECT ST_Distance(ST_MakePoint(0,0)::geometry, ST_MakePoint(3,4)::geometry);")
if [[ "$dist" != "5" ]]; then
	echo "[smoke-${arch}] FAIL: ST_Distance returned '${dist:-<empty>}' (expected 5)" >&2
	exit 1
fi
echo "[smoke-${arch}] spatial op ST_Distance((0,0),(3,4)) = ${dist}"

echo "[smoke-${arch}] PASS"
