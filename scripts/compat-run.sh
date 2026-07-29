#!/usr/bin/env bash
# Extension-compatibility scenario driver for the convoy-postgres product image.
#
# Usage: compat-run.sh <glitchtip|umami|prefect> [results-json]
#
# Brings up a convoy-postgres container (the WU3 product image, PG18 + PostGIS
# 3.6 + pgmq 1.10), runs the named add-on's database migration against it, then
# asserts the expected schema tables exist in the DB (DB-side proof of a clean
# migration). The signal this isolates is whether the add-on's ORM/migration
# engine (Django/Prisma/Alembic) accepts PostgreSQL 18 — not full-app HTTP health.
#
# The product image is built ONCE by the Make `compat-build` target (tagged
# convoy-postgres:18-3.6-compat) and reused across scenarios; this script does
# NOT build it. Full-app HTTP boot, Valkey/Redis, and worker processes are out of
# scope — the migration step is the PG-compatibility probe.
#
# Mirrors scripts/smoke-run.sh structure: a dedicated docker network per run, a
# TCP readiness gate (pg_isready -h 127.0.0.1, NOT bare pg_isready — the latter
# resolves the temp init-server Unix socket and reports a false ready before
# initdb finishes), a trap that dumps container diagnostics on failure then
# cleans up, and structured [compat-<app>] markers on stdout.
#
# Output: a JSON result object is merged into the results-json file (default
# build/compat-results.json) capturing per-add-on name, pinned image/version,
# status (pass/fail), migration_ok, schema tables verified, pg version, notes,
# and duration. The per-run migrate log is written to build/compat-<app>.log.
# Both are CI artifacts (build/ is gitignored, like the multiarch OCI tarball).
#
# An HONEST pass/fail is the deliverable: a migration failure (e.g. Prisma's
# engine rejecting PG18 catalog introspection) is captured as a fail result with
# the exact error, not forced green. The remediation path is carried into PN1.
#
# Thin Convoy helper (CONVOY-FORK.md WU6). No new toolchain — uses docker + psql
# (exec'd inside the PG container) + jq (host). jq is preinstalled on the
# ubuntu-24.04 CI runner; locally it is a common host prerequisite, not a
# TOOLSPEC-mandated one (TOOLSPEC lists Docker/Compose/Buildx/Make 4.3/Bash 5/Go).

set -euo pipefail

app=${1:?usage: compat-run.sh <glitchtip|umami|prefect> [results-json]}
results_json=${2:-build/compat-results.json}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version=18-3.6
pg_tag="convoy-postgres:${version}-compat"
pg_user=postgres
pg_pass=smoke
pg_container="compat-${app}-pg-$$"
app_container="compat-${app}-app-$$"
net="compat-net-${app}-$$"
build_dir="$root/build"
migrate_log="$build_dir/compat-${app}.log"

# --- per-add-on configuration -------------------------------------------------
# Each branch sets: the add-on image+version, the env vars the migration needs,
# the entrypoint/cmd override that isolates the migrate step, and the DB-side
# schema assertions (query + expectation) that prove the migration landed.
case "$app" in
glitchtip)
	app_image="glitchtip/glitchtip:6.2.2"
	app_version="6.2.2"
	pg_db="glitchtip"
	# Django migrate via manage.py. No entrypoint on the image (CMD is start.sh),
	# so the command overrides CMD directly. DATABASE_URL is parsed by
	# dj-database-url; SECRET_KEY is required by Django settings.
	app_env=(-e "DATABASE_URL=postgres://${pg_user}:${pg_pass}@${pg_container}:5432/${pg_db}"
		-e "SECRET_KEY=compat-dummy-key-not-for-production")
	app_entry=()
	app_cmd=(python manage.py migrate)
	# Schema proof: django_migrations has applied rows + a GlitchTip table exists.
	# The org model is ExtOrganization (custom), so the table is
	# organizations_ext_organization, not organizations_organization.
	schema_q=("SELECT count(*) FROM django_migrations;"
		"SELECT to_regclass('organizations_ext_organization');")
	schema_x=("ge1" "notnull")
	;;
umami)
	app_image="umamisoftware/umami:3.2.0"
	app_version="3.2.0 (Prisma 7.8.0)"
	pg_db="umami"
	# prisma migrate deploy (npm run update-db). HIGHEST PG18 risk: Prisma's
	# migration engine introspects the PG catalog and may reject PG18. The image
	# entrypoint (node docker-entrypoint.sh) is bypassed via --entrypoint npm.
	app_env=(-e "DATABASE_URL=postgresql://${pg_user}:${pg_pass}@${pg_container}:5432/${pg_db}")
	app_entry=(--entrypoint npm)
	app_cmd=(run update-db)
	# Schema proof: user + website tables exist (Umami v3 core entities; v2's
	# account table was renamed to user in v3).
	schema_q=("SELECT to_regclass('user');"
		"SELECT to_regclass('website');")
	schema_x=("notnull" "notnull")
	;;
prefect)
	app_image="prefecthq/prefect:3.8.0-python3.12"
	app_version="3.8.0 (python3.12)"
	pg_db="prefect"
	# Alembic upgrade to head. PREFECT_API_DATABASE_CONNECTION_URL drives the
	# SQLAlchemy connection. The prefecthq/prefect image ships asyncpg (not
	# psycopg3), so the +asyncpg dialect is required. The image entrypoint
	# (tini+entrypoint.sh) is bypassed via --entrypoint prefect.
	app_env=(-e "PREFECT_API_DATABASE_CONNECTION_URL=postgresql+asyncpg://${pg_user}:${pg_pass}@${pg_container}:5432/${pg_db}")
	app_entry=(--entrypoint prefect)
	app_cmd=(server database upgrade --yes)
	# Schema proof: alembic_version has a row + a Prefect ORM table exists.
	schema_q=("SELECT count(*) FROM alembic_version;"
		"SELECT to_regclass('flow_run');")
	schema_x=("ge1" "notnull")
	;;
*)
	echo "compat: unknown app '${app}' (expected glitchtip|umami|prefect)" >&2
	exit 2
	;;
esac

# Guard: the shared product image must exist (built by `make compat-build`).
if ! docker image inspect "$pg_tag" >/dev/null 2>&1; then
	echo "[compat-${app}] FAIL: product image ${pg_tag} not found" >&2
	echo "[compat-${app}] (run 'make compat-build' or 'make compat' first)" >&2
	exit 2
fi

mkdir -p "$build_dir"
start=$SECONDS
echo "[compat-${app}] START addon=${app_image} pg=${pg_tag} db=${pg_db}"

# --- network + containers -----------------------------------------------------
docker network create "$net" >/dev/null

# On any non-zero exit, capture why containers died BEFORE cleanup. Every docker
# call in the trap is guarded (|| true) so the trap never masks the original
# error. Happy-path exits (rc 0) skip diagnostics, so a passing scenario stays
# quiet (mirrors smoke-run.sh).
dump_diag() {
	local rc=$1
	[[ $rc -ne 0 ]] || return 0
	echo "[compat-${app}] DIAG exit=${rc}: capturing container state + logs" >&2
	for c in "$pg_container" "$app_container"; do
		docker inspect --format \
			'{{.Name}} state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err={{.State.Error}}' \
			"$c" >&2 2>&1 || true
		echo "[compat-${app}] DIAG ${c} logs (tail):" >&2
		docker logs --tail 30 "$c" >&2 2>&1 || true
	done
	if [[ -f "$migrate_log" ]]; then
		echo "[compat-${app}] DIAG migrate log (tail):" >&2
		tail -n 30 "$migrate_log" >&2 2>&1 || true
	fi
}

cleanup() {
	docker rm -f "$pg_container" "$app_container" >/dev/null 2>&1 || true
	docker network rm "$net" >/dev/null 2>&1 || true
}

trap 'rc=$?; dump_diag "$rc"; cleanup' EXIT

echo "[compat-${app}] RUN pg=${pg_container} (POSTGRES_DB=${pg_db})"
docker run -d --name "$pg_container" --network "$net" \
	-e POSTGRES_PASSWORD="$pg_pass" -e POSTGRES_DB="$pg_db" \
	"$pg_tag" >/dev/null

# Wait for Postgres to accept TCP connections. Bare pg_isready resolves the temp
# init-server Unix socket and returns a false ready before initdb finishes (the
# readiness race documented in CONVOY-FORK.md); -h 127.0.0.1 discriminates the
# real post-init server. 120s is generous for cross-arch emulation on CI.
echo "[compat-${app}] WAIT pg_isready (TCP)"
deadline=$((SECONDS + 120))
until docker exec "$pg_container" pg_isready -h 127.0.0.1 -p 5432 -U postgres >/dev/null 2>&1; do
	if ((SECONDS >= deadline)); then
		echo "[compat-${app}] FAIL: Postgres not ready within 120s" >&2
		docker logs "$pg_container" >&2 2>&1 || true
		exit 1
	fi
	sleep 1
done
echo "[compat-${app}] READY"

# Capture the PG version the product image reports (the headline compat axis).
pg_version=$(docker exec "$pg_container" psql -U postgres -d "$pg_db" -tAc "SELECT version();" 2>/dev/null | head -n1)
pg_version=${pg_version:-unknown}
echo "[compat-${app}] pg_version: ${pg_version%% (*}"

# --- migration (capture failure, do NOT abort) --------------------------------
# set -e is disabled around the migrate so a failure is recorded as a fail
# result, not an abort. The whole point is an HONEST pass/fail matrix.
echo "[compat-${app}] MIGRATE ${app_image}"
set +e
docker run --rm --name "$app_container" --network "$net" \
	"${app_env[@]}" "${app_entry[@]}" "$app_image" "${app_cmd[@]}" \
	>"$migrate_log" 2>&1
migrate_rc=$?
set -e

migration_ok=false
notes=""
if [[ $migrate_rc -eq 0 ]]; then
	migration_ok=true
	echo "[compat-${app}] MIGRATE-OK"
else
	# Capture the tail of the migrate log as the headline failure evidence.
	notes="migrate exit=${migrate_rc}; $(tail -n 3 "$migrate_log" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-300)"
	echo "[compat-${app}] MIGRATE-FAIL (exit ${migrate_rc}) — see ${migrate_log#"$root"/}"
fi

# --- schema assertions (DB-side proof) ----------------------------------------
# Run regardless of migrate rc: a partial migration may still leave tables, and
# the absence of expected tables is itself the compat signal.
set +e
schema_lines=()
schema_ok=true
for i in "${!schema_q[@]}"; do
	q="${schema_q[$i]}"
	exp="${schema_x[$i]}"
	val=$(docker exec "$pg_container" psql -U postgres -d "$pg_db" -tAc "$q" 2>/dev/null | head -n1)
	val=${val:-}
	case "$exp" in
	ge1)
		if [[ "$val" =~ ^[0-9]+$ ]] && ((val >= 1)); then
			schema_lines+=("ok: ${q}")
		else
			schema_ok=false
			schema_lines+=("FAIL: ${q} -> '${val:-<empty>}' (expected >=1)")
		fi
		;;
	notnull)
		if [[ -n "$val" ]]; then
			schema_lines+=("ok: ${q} -> ${val}")
		else
			schema_ok=false
			schema_lines+=("FAIL: ${q} -> NULL (expected a table)")
		fi
		;;
	esac
done
set -e

if $schema_ok; then
	echo "[compat-${app}] SCHEMA-PASS"
else
	echo "[compat-${app}] SCHEMA-FAIL"
fi

duration=$((SECONDS - start))

# --- verdict + JSON result ----------------------------------------------------
status=fail
if $migration_ok && $schema_ok; then
	status=pass
fi

if [[ "$status" == "pass" ]]; then
	echo "[compat-${app}] PASS (${duration}s)"
else
	echo "[compat-${app}] FAIL (${status}; ${duration}s)"
fi

# Build the result object with jq (safe string escaping).
schema_joined=$(printf '%s\n' "${schema_lines[@]}")
result=$(jq -n \
	--arg name "$app" \
	--arg image "$app_image" \
	--arg app_version "$app_version" \
	--arg status "$status" \
	--argjson migration_ok "$migration_ok" \
	--arg schema_verified "$schema_joined" \
	--arg pg_version "$pg_version" \
	--arg notes "$notes" \
	--argjson duration_s "$duration" \
	'{name:$name, image:$image, app_version:$app_version, status:$status,
      migration_ok:$migration_ok, schema_verified:($schema_verified|split("\n")),
      pg_version:$pg_version, notes:$notes, duration_s:$duration_s}')

# Merge into the results file (append to the array; create if absent).
if [[ -f "$results_json" ]] && jq -e . "$results_json" >/dev/null 2>&1; then
	tmp=$(mktemp)
	jq --argjson r "$result" '. + [$r]' "$results_json" >"$tmp" && mv "$tmp" "$results_json"
else
	printf '[%s]\n' "$result" >"$results_json"
fi

# Exit non-zero on fail so `make compat` surfaces it — but the result is recorded
# either way. The Make `compat` target runs all three regardless (it does not
# abort on the first failure).
[[ "$status" == "pass" ]]
