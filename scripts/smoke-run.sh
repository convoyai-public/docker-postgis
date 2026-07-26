#!/usr/bin/env bash
# Runnable per-architecture container smoke for the 18-3.6 PostGIS image.
#
# Usage: smoke-run.sh <arm64|amd64> [context-dir] [dockerfile]
#
# Builds the image for the target arch as a loadable single-arch image, starts a
# detached Postgres container, waits for it to accept connections, then asserts:
#   - the postgis extension is installed (read-only check; performs no DDL)
#   - postgis_full_version() reports a non-empty POSTGIS= string
#   - a basic spatial op (ST_Distance on two geometry points) returns 5
#   - pgmq can be CREATE EXTENSIONed and a queue round-trip returns the payload
# Structured [smoke-<arch>] markers go to stdout; failures go to stderr with a
# non-zero exit. The container is removed on any exit (trap). This script is the
# executable verification of the WU2 + WU3 acceptance criteria: the built image
# is RUNNABLE on each arch and carries both PostGIS and pgmq, not merely
# buildable.
#
# The optional [dockerfile] argument selects a Convoy-authored Dockerfile (e.g.
# dockerfiles/18-3.6.dockerfile, the WU3 pgmq-bearing product image) and is
# passed to buildx as -f. When omitted, the upstream image in [context-dir] is
# built unchanged (the WU1 baseline behavior).
#
# Thin Convoy helper (CONVOY-FORK.md). No publish/registry logic (that is WU4).
# Buildx is a TOOLSPEC host prerequisite; this script adds no new toolchain.

set -euo pipefail

arch=${1:?usage: smoke-run.sh <arm64|amd64> [context-dir] [dockerfile]}
case "$arch" in
arm64 | amd64) ;;
*)
	echo "smoke: invalid arch '$arch' (expected arm64|amd64)" >&2
	exit 2
	;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
context=${2:-$root/18-3.6}
dockerfile=${3:-}
version=18-3.6
tag="convoy-postgres:${version}-smoke-${arch}"
container="convoy-postgres-smoke-${arch}-$$"

# Relative context for the START marker. When the Convoy product Dockerfile is
# selected the context is the repo root, which collapses to ".".
rel=${context#"$root"}
rel=${rel#/}
rel=${rel:-.}

echo "[smoke-${arch}] START platform=linux/${arch} image=${tag} context=${rel}"

# Build a loadable single-arch image. --load requires exactly one --platform.
# When a Convoy Dockerfile is supplied, pass it via -f (context stays the arg).
echo "[smoke-${arch}] BUILD (buildx --load; amd64 is emulated on Apple Silicon)"
if [[ -n "$dockerfile" ]]; then
	docker buildx build --platform "linux/${arch}" --load -f "$dockerfile" -t "$tag" "$context"
else
	docker buildx build --platform "linux/${arch}" --load -t "$tag" "$context"
fi

# On any non-zero exit, capture why the container died BEFORE cleanup removes
# it. Every docker call in the trap is guarded (|| true) so the trap itself
# never masks the original error. Happy-path exits (rc 0) skip diagnostics,
# so a passing smoke stays quiet.
dump_diag() {
	local rc=$1
	[[ $rc -ne 0 ]] || return 0
	[[ -n "${container:-}" ]] || return 0
	echo "[smoke-${arch}] DIAG exit=${rc}: capturing container state + logs" >&2
	docker inspect --format \
		'{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err={{.State.Error}} startedAt={{.State.StartedAt}} finishedAt={{.State.FinishedAt}}' \
		"$container" >&2 2>&1 || true
	echo "[smoke-${arch}] DIAG docker logs:" >&2
	docker logs "$container" >&2 2>&1 || true
}

cleanup() {
	if [[ -n "${container:-}" ]]; then
		docker rm -f "$container" >/dev/null 2>&1 || true
	fi
}

trap 'rc=$?; dump_diag "$rc"; cleanup' EXIT

echo "[smoke-${arch}] RUN container=${container}"
docker run -d --name "$container" --platform "linux/${arch}" \
	-e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=postgres \
	"$tag" >/dev/null

# Wait for Postgres to accept connections. 120s is generous for amd64 emulation.
echo "[smoke-${arch}] WAIT readiness (pg_isready)"
deadline=$((SECONDS + 120))
until docker exec "$container" pg_isready -h 127.0.0.1 -p 5432 -U postgres >/dev/null 2>&1; do
	if ((SECONDS >= deadline)); then
		echo "[smoke-${arch}] FAIL: Postgres not ready within 120s" >&2
		docker logs "$container" >&2 2>&1 || true
		exit 1
	fi
	sleep 1
done
echo "[smoke-${arch}] READY"

# Run an assertion psql. A stopped container yields only a bare daemon error
# from docker exec, so on failure detect that case and print an explicit FAIL
# line before set -e aborts (the EXIT trap's DIAG dump then follows). Returns
# the exec's rc so non-zero still propagates and fails the script.
psql() {
	local rc=0
	docker exec "$container" psql -U postgres -d postgres -tAc "$@" || rc=$?
	if [[ $rc -ne 0 ]]; then
		local status
		status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo unknown)
		if [[ "$status" != "running" ]]; then
			echo "[smoke-${arch}] FAIL: container stopped before/during assertion (see DIAG output above)" >&2
		fi
	fi
	return "$rc"
}

# Assertion 1: postgis is installed. The entrypoint's init script
# (10_postgis.sh) already runs "CREATE EXTENSION IF NOT EXISTS postgis" during
# init, so the smoke only VERIFIES the row exists (read-only). Performing DDL
# here would re-run that same statement concurrently with the init script under
# the temp init server: "CREATE EXTENSION IF NOT EXISTS" is check-then-insert
# and is not atomic, so the loser hits a duplicate key on pg_extension_name_index
# and (with ON_ERROR_STOP=1) aborts init -> container exit 3. Read-only here
# eliminates that race. set -e makes a failed psql exec (e.g. stopped container)
# fatal regardless.
postgis_count=$(psql "SELECT count(*) FROM pg_extension WHERE extname = 'postgis';")
if [[ "$postgis_count" != "1" ]]; then
	echo "[smoke-${arch}] FAIL: postgis extension not installed (count='${postgis_count:-<empty>}'; expected 1)" >&2
	exit 1
fi
echo "[smoke-${arch}] postgis installed: ok"

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

# Assertion 4 (WU3): pgmq is bundled and a queue round-trip works.
#
# Unlike postgis, pgmq has NO initdb-script creator, so CREATE EXTENSION pgmq
# here is the sole creator. There is therefore no check-then-insert race with
# the init server, and the plain CREATE is safe. It still MUST run after the
# TCP readiness gate above (pg_isready -h 127.0.0.1), which discriminates the
# post-init real server from the Unix-socket-only temp init server — see
# CONVOY-FORK.md "Postgres smoke readiness race". Ordering is: TCP gate ->
# read-only postgis checks -> pgmq create + round-trip.
#
# The pgmq control file pins schema=pgmq (not on the default search_path), so
# every call is schema-qualified. Signatures verified against pgmq.sql at the
# v1.10.0 tag: pgmq.create(text) returns void;
# pgmq.send(text, jsonb) returns SETOF bigint;
# pgmq.read(text, vt int, qty int [, conditional jsonb]) returns
# SETOF pgmq.message_record (whose `message jsonb` column carries the payload).
if ! psql "CREATE EXTENSION pgmq;" >/dev/null 2>&1; then
	echo "[smoke-${arch}] FAIL: CREATE EXTENSION pgmq failed" >&2
	exit 1
fi
echo "[smoke-${arch}] pgmq extension created: ok"

if ! psql "SELECT pgmq.create('smoke_queue');" >/dev/null 2>&1; then
	echo "[smoke-${arch}] FAIL: pgmq.create('smoke_queue') failed" >&2
	exit 1
fi
echo "[smoke-${arch}] pgmq queue created: smoke_queue"

sent_id=$(psql "SELECT pgmq.send('smoke_queue', '{\"ping\": \"pong\"}'::jsonb);")
if [[ -z "${sent_id}" ]]; then
	echo "[smoke-${arch}] FAIL: pgmq.send returned no msg_id" >&2
	exit 1
fi

payload=$(psql "SELECT message->>'ping' FROM pgmq.read('smoke_queue', 30, 1);")
if [[ "$payload" != "pong" ]]; then
	echo "[smoke-${arch}] FAIL: pgmq.read payload='${payload:-<empty>}' (expected 'pong')" >&2
	exit 1
fi
echo "[smoke-${arch}] pgmq round-trip: send msg_id=${sent_id}, read payload='pong'"

echo "[smoke-${arch}] PASS"
