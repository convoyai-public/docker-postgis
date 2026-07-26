# Convoy-authored Dockerfile for the `convoy-postgres` product image (18-3.6).
#
# This is NOT the upstream-generated Dockerfile. Upstream's 18-3.6/Dockerfile is
# apt-package-based (PostGIS via PGDG) and is left untouched; this file layers
# pgmq on top of the SAME PostGIS layer and is the image the runnable smoke and
# multi-arch build targets consume (CONVOY-FORK.md, WU3).
#
# Build context MUST be the repo root (so 18-3.6/initdb-postgis.sh is in
# context):
#     docker buildx build -f dockerfiles/18-3.6.dockerfile .
#
# pgmq v1.10.0 is a PURE-SQL extension (39 plpgsql + 15 sql functions, no C, no
# .so) at this tag; `make install` installs only the control file and the SQL
# transition files into the PG18 extension datadir. Verified by inspecting the
# builder output. There is therefore no shared-library COPY — only the datadir
# glob. PG18 build is proven by the runnable smoke (CREATE EXTENSION +
# round-trip); the upstream README lists PG14-17, but a pure-SQL extension is
# version-portable and PG18 is verified here.

# --- Stage 1: build + install pgmq against the PG18 server headers -------------
FROM postgres:18-trixie AS pgmq-builder

# Build deps are intentionally unpinned (throwaway builder stage; pinning
# volatile apt versions here would churn without benefit). --no-install-recommends
# keeps the layer minimal; list cleanup prevents apt cache leakage.
# hadolint ignore=DL3008
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		build-essential \
		postgresql-server-dev-18 \
		git \
		ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

# Shallow-clone the pinned pgmq tag and PGXS-install it. PG_CONFIG points at the
# PG18 server (the postgres:18-trixie base ships /usr/lib/postgresql/18/bin/
# pg_config), so the build resolves PG18 headers and installs into the PG18
# extension dirs. `make ... install` runs the `all` target first (creates the
# versioned pgmq--1.10.0.sql) then installs control + SQL.
RUN git clone --depth 1 --branch v1.10.0 https://github.com/pgmq/pgmq /tmp/pgmq \
	&& make -C /tmp/pgmq/pgmq-extension \
		PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config install

# --- Stage 2: final runtime image — PostGIS (apt) + pgmq (from builder) -------
FROM postgres:18-trixie

LABEL org.opencontainers.image.description="PostGIS 3.6.4 + pgmq 1.10.0 on PostgreSQL 18 trixie (Convoy)" \
	org.opencontainers.image.source="https://github.com/convoyai-public/docker-postgis"

ENV POSTGIS_MAJOR=3
ENV POSTGIS_VERSION=3.6.4+dfsg-2.pgdg13+1

# PostGIS layer: mirrors upstream 18-3.6/Dockerfile (pinned postgis,
# --no-install-recommends, list cleanup). ca-certificates and the -scripts
# package are unpinned to match upstream exactly.
# hadolint ignore=DL3008
RUN apt-get update \
	&& apt-cache showpkg "postgresql-${PG_MAJOR}-postgis-${POSTGIS_MAJOR}" \
	&& apt-get install -y --no-install-recommends \
		ca-certificates \
		"postgresql-${PG_MAJOR}-postgis-${POSTGIS_MAJOR}=${POSTGIS_VERSION}" \
		"postgresql-${PG_MAJOR}-postgis-${POSTGIS_MAJOR}-scripts" \
	&& rm -rf /var/lib/apt/lists/*

# pgmq layer: copy the extension control + SQL files installed in the builder
# into the matching PG18 extension datadir. No .so is produced (pure-SQL
# extension), so there is no shared-library COPY. The glob brings in pgmq.control
# plus pgmq--1.10.0.sql and every pgmq--*--*.sql transition file.
COPY --from=pgmq-builder /usr/share/postgresql/18/extension/pgmq* /usr/share/postgresql/18/extension/

# PostGIS initdb + update scripts, matching upstream 18-3.6/Dockerfile. Build
# context is the repo root, so the paths are under 18-3.6/.
RUN mkdir -p /docker-entrypoint-initdb.d
COPY 18-3.6/initdb-postgis.sh /docker-entrypoint-initdb.d/10_postgis.sh
COPY 18-3.6/update-postgis.sh /usr/local/bin/
