<!-- CONVOY-FORK-DOC -->
# Convoy fork of `postgis/docker-postgis`

This repository is a **true fork** of the upstream
[`postgis/docker-postgis`](https://github.com/postgis/docker-postgis) project.
Full upstream history is preserved. Upstream remains the source of truth for the
generated Dockerfiles, the `update.sh` generator, and the per-version image
recipes; this fork layers Convoy's packaging, validation, and release concerns
on top without reimplementing upstream's work.

The **published image name is `convoy-postgres`**. The publishing topology,
multi-registry parity, SBOM/provenance, and cosign signing are established in
WU4 of the convoy-deploy Phase 1 plan and are **out of scope** for this work
unit (WU1). WU1 only stands up the repo substrate, the local validation/tooling
scaffold, and thin CI. (WU4 landed GAR-primary triple publish + keyless cosign;
see the [WU4 design record](#wu4-pr-validation--signed-multi-registry-multi-arch-publish-pipeline)
for the authoritative topology.)

The authoritative tooling policy is
[`convoy-deploy`'s `specs/TOOLSPEC.md`](https://github.com/convoyai/convoy-deploy/blob/main/specs/TOOLSPEC.md),
especially its `convoy-postgres Tooling` section. This document does not repeat
that policy; it records how this fork implements it and where it deliberately
diverges from upstream.

## Branch model

| Branch | Role |
| --- | --- |
| `convoy-vendor` | Pristine mirror of upstream `master`. Fast-forward only. **Never carries Convoy patches.** Currently at upstream `2bcd236`. |
| `main` | The default branch. `convoy-vendor` merged forward, plus Convoy's layered additions (this fork's docs, `GNUmakefile`, `tools/`, `scripts/`, workflows). This is the PR base. |
| `master` | Inherited upstream default; retained on the fork for history. Do **not** commit here. |
| `upstream` (remote) | Tracks `https://github.com/postgis/docker-postgis.git`, used only for merge-forward. |
| `origin` (remote) | `git@github.com:convoyai-public/docker-postgis.git` (this fork). |

Feature branches (e.g. `mark/eng-517-...`) are cut from `main` and merged back
to `main`. Releases are tagged on `main`.

## Merge-forward procedure (upstream sync)

Upstream synchronization is a **reviewed, manual merge** — automation never
rewrites `convoy-vendor` or `main` and never publishes a release without an
operator decision (TOOLSPEC). The procedure is:

1. Fetch upstream.

   ```bash
   git fetch upstream
   ```

2. Fast-forward the pristine vendor mirror (no Convoy content here, ever).

   ```bash
   git checkout convoy-vendor
   git merge --ff-only upstream/master
   git push origin convoy-vendor
   ```

3. Open a feature branch from `main` and merge the vendor mirror forward.

   ```bash
   git checkout main && git pull --ff-only
   git checkout -b sync/upstream-<short-sha>
   git merge convoy-vendor
   ```

4. Resolve conflicts. The known conflict points are listed in
   [Deliberate divergences](#deliberate-divergences-from-upstream); each is
   intentionally owned by Convoy and re-applied on every merge.
5. Run the local gate.

   ```bash
   gmake presubmit   # macOS; `make presubmit` on Linux
   ```

6. Open a PR to `main`. The scheduled `make vendor-audit` reports upstream
   commits not yet on `convoy-vendor` (see [Vendor audit](#vendor-audit)) — it
   is a backstop, not the sync trigger.

## Local tool entry point

- **macOS:** use Homebrew GNU Make as `gmake` (`brew install make`). The BSD
  system `/usr/bin/make` is **unsupported** and is rejected by the version
  guard in `GNUmakefile` (TOOLSPEC).
- **Linux:** use `make` (GNU Make 4.4+).

`GNUmakefile` is the entry point. GNU Make prefers `GNUmakefile` over
`Makefile`, so it becomes the front door **without editing upstream's
`Makefile`** (keeping vendor merges clean). It `-include`s the upstream
`Makefile` so upstream's `build`/`test`/`push` targets remain available; it then
layers Convoy targets on top:

| Target | Purpose |
| --- | --- |
| `help` | Document supported targets and prerequisites. |
| `tools` / `tools-audit` | Populate / inspect the pinned tool cache (`tools/tools.yaml`). |
| `validate` | Run the static validators (actionlint, Zizmor, Hadolint, ShellCheck, shfmt, Gitleaks, markdownlint) over **Convoy-owned** inputs. |
| `format` / `lint` | Format check / lint. |
| `generated-check` | Reject drift in committed generated output (extensible; no-op pass-through in WU1). |
| `smoke` | Build the **unmodified upstream image** for one representative version (`18-3.6`) natively, proving the baseline builds (build-only; WU1). |
| `smoke-arm64` / `smoke-amd64` | **Runnable** per-arch smoke (WU2): buildx `--load` + run a container + `CREATE EXTENSION postgis` + `postgis_full_version()` + a spatial op. Proves the image is *runnable* on each arch, not merely buildable. `smoke-amd64` is emulated on Apple Silicon. |
| `smoke-native` | Runnable smoke for the Docker daemon's native arch (fast; no emulation). Used by `presubmit`. |
| `smoke-multiarch` | Runnable smoke on **both** arches (`smoke-arm64` + `smoke-amd64`). |
| `build-multiarch` | Assemble a local **multi-arch manifest** (`linux/amd64,linux/arm64`) to an OCI-layout tarball under `build/` **without publishing**. Proves both arches build into one manifest. |
| `vendor-audit` | Report upstream commits on `upstream/master` not present on `convoy-vendor`. |
| `presubmit` | Local equivalent of the fast PR tier: `validate` (shfmt + lints + `generated-check`) + `smoke-native` (runnable native-arch smoke). |
| `scan` / `sbom` / `sign` / `parity` | WU4 **publish gates**: Grype policy scan, Syft CycloneDX SBOM, keyless cosign sign + attest, and cross-registry manifest parity. Invoked by the tag-triggered `publish.yml` after the multi-arch push; each fails the publish job on its respective regression. |

Local **multi-arch assembly** (`build-multiarch`) and **runnable per-arch smoke**
(`smoke-*`) are WU2. The **publish gates** (`scan` / `sbom` / `sign` / `parity`)
are WU4 and are invoked by `.github/workflows/publish.yml`; `build-multiarch`
writes only a local OCI tarball and never publishes.

## Validation scoping (important)

The static gates guard **Convoy-owned inputs only**:

- ShellCheck / shfmt lint `scripts/*.sh` (Convoy's thin Bash 5 helpers).
- Hadolint lints Convoy-authored Dockerfiles (e.g. `dockerfiles/18-3.6.dockerfile`).
- actionlint / Zizmor lint `.github/workflows/*.yml` (Convoy-owned).
- markdownlint lints Convoy-authored Markdown (this file; the README banner
  block).
- Gitleaks scans the whole tree (it is content-based, not ownership-based).

Upstream's generated Dockerfiles (`*/Dockerfile`, `*/alpine/Dockerfile`), the
`update.sh` generator, `initdb-postgis.sh`, `apply-readme.sh`, `test/`,
`examples/`, upstream's `Makefile`, and the upstream `README.md` body are
**excluded** from the gates. They are upstream-owned; re-linting them on every
vendor merge would make the gate churn constantly and would police work Convoy
does not own. Upstream quality is upstream's responsibility — the
[`vendor-audit`](#vendor-audit) target tracks upstream motion instead.

This is the concrete expression of TOOLSPEC's vendor-merge-cleanliness
principle: the gates guard our contributions, and they stay green across vendor
merges because they never assert over upstream-tracked content.

## Vendor audit

`make vendor-audit` runs `scripts/vendor-audit.sh`, which prints the upstream
commits on `upstream/master` that are not yet on `convoy-vendor`. It exits `0`
with an "in sync" message when there are none. The scheduled
`vendor-audit.yml` workflow runs the same target weekly and uploads the report
as an artifact. It is a **backstop**: it reports drift; it never performs or
merges the sync.

## Deliberate divergences from upstream

These are the only intentional edits to upstream-tracked files. Each is a known
**vendor-merge conflict point** and is re-applied (trivially, thanks to the
marker comments) on every merge-forward.

| Path | Change | Why |
| --- | --- | --- |
| `.circleci/` | **Removed** | Dead upstream CI we do not use; we own CI via GitHub Actions. |
| `.travis.yml.disabled` | **Removed** | Dead upstream CI we do not use. |
| `.github/workflows/main.yml` | **Replaced** by `ci.yml` | Upstream's matrix build policy is replaced by thin plumbing that invokes `make presubmit` (TOOLSPEC: no build/test policy in YAML). |
| `README.md` | **Top banner only** | A single `<!-- CONVOY-FORK-TOP -->` ... `<!-- /CONVOY-FORK-TOP -->` block at the very top identifies the fork. The upstream README body is otherwise untouched. |

Everything else Convoy adds is **new files alongside upstream** (`CONVOY-FORK.md`,
`GNUmakefile`, `scripts/`, `tools/`, `.github/workflows/ci.yml`,
`.github/workflows/vendor-audit.yml`, `.github/CODEOWNERS`,
`.markdownlint-cli2.jsonc`, `.hadolint.yaml`), so vendor merges never touch
them.

## WU2: ARM build enablement

ENG-518 ports the *intent* of the local clone's `mark/enable-arm-builds`
(`3975a0e`) — multi-arch buildx + native-arch runnable smoke, amd64 preserved —
onto the fork's **product image `18-3.6`** and the fork's **`GNUmakefile`** front
door. It does **not** replay `3975a0e` literally:

- `3975a0e` bumps `PROJ/GDAL/POSTGIS_GIT_HASH` in the **source-build**
  `16-master`/`17-master` Dockerfiles (those compile the geo stack from git; the
  old hashes fail to compile on arm64) and switches the **upstream** `Makefile`
  `build-$(version)` macro to `docker buildx build --platform linux/amd64,linux/arm64`.
- The Convoy product image `18-3.6/Dockerfile` is **28 lines, apt-package-based**
  (`FROM docker.io/postgres:18-trixie` + `postgresql-18-postgis-3` from the PGDG
  apt repo). It compiles nothing and pins no git hashes; the base image and PGDG
  both ship arm64, so it is already arm64-compatible. The source-build
  `16/17/18-master` images are **not** Convoy product and are out of scope.

So: no source-hash bump is needed, the upstream `Makefile` is untouched (per the
`-include Makefile` vendor-clean pattern), and all new targets layer in
`GNUmakefile` + `scripts/smoke-run.sh`. The `3975a0e` hash-bump technique is
recorded here as the recipe to reuse **if** a source-build image is ever
productized on arm64.

**Design notes:**

- `build-multiarch` assembles a multi-arch manifest for
  `linux/amd64,linux/arm64` to a **local** OCI-layout tarball
  (`build/<repo>-<ver>-multiarch.oci.tar`, gitignored) via
  `docker buildx build --output type=oci,dest=...`. It does **not** publish
  (publish/sign/registry is WU4). `--load` is intentionally not used here:
  `--load` cannot carry more than one platform, so multi-arch proof uses
  `--output type=oci` instead.
- `smoke-arm64`/`smoke-amd64` build a **loadable single-arch** image
  (`buildx --platform linux/<arch> --load`) and then **run** it
  (`docker run --platform linux/<arch>`), wait on `pg_isready`, and assert
  `CREATE EXTENSION postgis`, `postgis_full_version()`, and a 3-4-5 spatial
  distance. `smoke-amd64` runs under QEMU emulation on Apple Silicon; both pass.
- `presubmit` runs `validate` + `smoke-native` (the daemon-native runnable
  smoke), so the fast PR tier now proves the baseline is **runnable**, not just
  buildable. `smoke` (build-only) remains as a standalone quick check.

**Warn-not-gate ARM posture for 18-3.6 (finding for WU4):** the apt-based
`18-3.6` image has **no fragile ARM source-build test surface**. The upstream
regress-suite flakiness that motivates a warn-not-gate posture lives in the
source-build `16/17-master` images (PROJ/GDAL/PostGIS compiled from git, with
their full `make check`/regress suites). For `18-3.6`, PostGIS 3.6.4 is installed
as a **prebuilt PGDG Debian package**; PGDG build and test it upstream, and this
fork runs **no** geo source test suites. The only test surface is the runnable
extension smoke, whose assertions (`postgis_full_version()` reports, exact 3-4-5
`ST_Distance`) are deterministic and arch-independent. **Recommendation for
WU4:** the runnable extension smoke should fully **gate** for `18-3.6`; there is
nothing to relax into a warn for this image. The warn-not-gate knob only becomes
relevant if a source-build image is productized — then the `3975a0e` hash recipe
and the upstream regress-suite arm64 flakiness would apply.

**Local mode caveat (macOS):** the postgres entrypoint *sources*
`/docker-entrypoint-initdb.d/10_postgis.sh` as the `postgres` user, so the file
must be world-readable. Git tracks it as mode `100644` (the intended, clean state
on Linux/CI), but some macOS checkouts land it at `0640`, which breaks container
init (`Permission denied`) and is invisible to `git status` (git tracks only the
execute bit). If a runnable smoke fails with `Permission denied` on
`10_postgis.sh`, fix the working-tree mode to match the committed intent:

```bash
chmod 0644 initdb-postgis.sh 18-3.6/initdb-postgis.sh
```

This is a filesystem-mode correction, not a content edit; it creates no
vendor-merge conflict and leaves `git status` clean.

## WU3: pgmq bundling into the image

ENG-519 bundles [pgmq](https://github.com/pgmq/pgmq) into the `convoy-postgres`
product image (it is absent from the interim `markfrommn/postgis` image). pgmq
has no PGDG apt package, so it is built from source and layered on the same
PostGIS layer the upstream image ships. The first compound tag (`PG-major –
PostGIS – pgmq`) is cut in WU5; WU3 only bundles pgmq and records its version.

**Pinned source:** `https://github.com/pgmq/pgmq` at tag **`v1.10.0`**
(full version `1.10.0`). The upstream README lists PostgreSQL 14–17; pgmq 1.10.0
is a **pure-SQL extension** (39 plpgsql + 15 sql functions, no C, no `.so`), so
it is version-portable, and PG18 support is proven by the runnable smoke below.
The build is therefore a PGXS `make install` against the PG18 server headers,
not a C compile.

**Design notes:**

- pgmq is delivered by a **new Convoy-authored multi-stage Dockerfile**
  (`dockerfiles/18-3.6.dockerfile`); the upstream-generated `18-3.6/Dockerfile`
  is **not edited** (vendor-merge cleanliness). A `pgmq-builder` stage
  (`FROM postgres:18-trixie`) installs `postgresql-server-dev-18` + build deps,
  shallow-clones the `v1.10.0` tag, and runs
  `make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config install`. The final stage
  reproduces the upstream PostGIS apt layer (functionally equivalent — `POSTGIS_VERSION` pinned,
  `--no-install-recommends`, list cleanup) and `COPY --from=pgmq-builder` the
  pgmq extension files into `/usr/share/postgresql/18/extension/`.
- **No shared-library COPY.** Verified by inspecting the builder output: pgmq
  1.10.0 ships only `pgmq.control` + the `pgmq--*.sql` transition files (the
  control file's `module_pathname = '$libdir/pgmq'` is a harmless stale field —
  the SQL contains no `MODULE_PATHNAME` substitutions and no `LANGUAGE C`
  functions). The COPY is a single datadir glob, `pgmq*`. Build context is the
  repo root (`.`) so `18-3.6/initdb-postgis.sh` is in context.
- The **runnable smokes and `build-multiarch`** now build the Convoy product
  Dockerfile (`-f dockerfiles/18-3.6.dockerfile`, context `.`); the build-only
  baseline `smoke` **stays on the unmodified upstream image** so it keeps
  proving the upstream baseline builds (WU1 intent). `scripts/smoke-run.sh`
  gained an optional dockerfile argument and a pgmq assertion.
- **Smoke round-trip proof:** after the TCP readiness gate and the read-only
  postgis checks, the smoke runs `CREATE EXTENSION pgmq` (the sole creator —
  pgmq has no initdb-script creator, so there is no check-then-insert race) and
  a queue round-trip. The pgmq control file pins `schema = pgmq` (not on the
  default `search_path`), so every call is schema-qualified against the v1.10.0
  signatures verified in `pgmq-extension/sql/pgmq.sql`:
  `pgmq.create(text)`, `pgmq.send(text, jsonb)` (returns `SETOF bigint`),
  `pgmq.read(text, vt int, qty int)` (returns `SETOF pgmq.message_record`,
  whose `message jsonb` column carries the payload). Both arches pass:
  `[smoke-<arch>] pgmq round-trip: send msg_id=1, read payload='pong'`.
- **Hadolint posture:** both `apt-get install` lines carry a justified
  `# hadolint ignore=DL3008` — the builder's build deps are unpinned by design
  (throwaway stage), and the final stage matches upstream's exact pattern
  (pinned `postgresql-18-postgis-3`, unpinned `ca-certificates` and `-scripts`).
  `failure-threshold: warning` is met with zero warning/error findings.

**Compound-tag-suffix input for WU5:** the recommended suffix is **`-pgmq1.10`**
(minor only, matching the spec's `pgmqX.Y` convention in the compound tag
`18-3.6-pgmqX.Y`); the full recorded pgmq version is `1.10.0`. WU5 cuts the
actual tag; WU3 only captures the version. The Phase 1 plan's `1.5`/`pgmq1.5`
placeholders were illustrative (`e.g.`); `1.10.0` is the pinned reality recorded
here.

## WU4: PR validation + signed multi-registry multi-arch publish pipeline

ENG-520 stands up the tag-triggered publish pipeline for the `convoy-postgres`
image. The PR-validation tier was already met by WU2/WU3: `ci.yml` runs
`make presubmit` (= `validate` + `smoke-native`) on PR and push-to-main, and for
this single-product repo `smoke-native` already builds AND RUNS the product image
(18-3.6 + pgmq), so the PR tier's static-validation + native-extension-smoke +
affected-build obligations are covered. WU4 does not duplicate that tier; its
focus is the new **`.github/workflows/publish.yml`** and the four publish gates
in `GNUmakefile`.

**Material deviation from spec — authorized.** `convoy-deploy`'s `TOOLSPEC.md`
is inaccurate on registry topology (it says GHCR is primary and the publish is
dual-registry). The corrected reality — implemented here and landed in a
companion convoy-deploy PR — is: **Google Artifact Registry (GAR) is primary**,
this is **triple publish** (GAR + Docker Hub + GHCR), and image-pipeline signing
is **keyless cosign (OIDC)**, not key-based. (Key-based cosign still governs the
separate Phase 3 convoy-deploy blob/convoyctl path and is out of scope here.)

**Trigger.** `on.push.tags: ['18-*-*']` filtered to the compound scheme, plus
`workflow_dispatch`. The `18-*-*` glob requires two dashes after `18-`, so it
matches `18-3.6-pgmq1.10` but not a plain upstream-style `18-3.6` tag. **No tag
is cut in this WU** — cutting the first compound tag is WU5/ENG-521; this WU
only ships the pipeline that fires it.

**Design notes:**

- **Registries (triple).** GAR primary
  `${GHA_GAR_HOST}/${GHA_GAR_PATH}/convoy-postgres`
  (`us-central1-docker.pkg.dev/containerhosting/convoy`), Docker Hub
  `${DH_REPO_MARK}/convoy-postgres`, GHCR
  `ghcr.io/${github.repository_owner}/convoy-postgres`. Three `docker/login-action`
  steps; GAR uses `google-github-actions/auth@v2` with a service-account JSON key
  (`GHA_GAR_CONTAINER_PUBLISH_KEY`) then `docker/login-action` with
  `username: _json_key`.
- **Tag — compound tag ONLY, no `latest`.** `docker/metadata-action` with
  `type=ref,event=tag` emits exactly the pushed compound tag for every image.
  There is deliberately **no** `type=raw,value=latest` and **no** `type=edge`.
  A run-time **no-latest assertion** step greps `metadata-action`'s emitted tags
  and fails the job if any `latest` slipped through, guarding the AC "No floating
  latest in either registry" defensively.
- **Multi-arch.** `linux/amd64,linux/arm64` via `docker/setup-qemu-action@v3` +
  `docker/setup-buildx-action@v3` + `docker/build-push-action@v6`, `push: true`,
  `file: dockerfiles/18-3.6.dockerfile` (the WU3 product Dockerfile), context `.`.
  Portable docker/* actions on `ubuntu-24.04` (NOT Blacksmith-wired; core-platform
  runs Blacksmith actions, which are not available to this repo).
- **Provenance/SBOM.** `provenance: mode=max`, `sbom: true` on build-push-action;
  `permissions: { attestations: write, id-token: write }`.
- **Gates live in `GNUmakefile`; plumbing in YAML** (TOOLSPEC). The irreducible
  docker-action plumbing is in `publish.yml`; the four gates (`scan` / `sbom` /
  `sign` / `parity`) are Make targets over the **already-pinned** tools
  (`grype`/`syft`/`cosign` in `BINARY_TOOLS`), each a thin `scripts/publish-*.sh`
  helper. The publish job runs the gates sequentially and **fails the job** on any
  scan-policy / signing / parity failure (WU4 AC).
- **Grype policy gate.** grype has **no `--policy` flag**; its policy mechanism
  is a configuration file consumed via `-c`. `.grype/policy.yaml` is that config:
  `fail-on-severity: high` is the hard gate, and `ignore: []` is the documented
  accept-list (empty at WU4 by design — the gate ships live; WU5's first scan
  surfaces the real CVE set, which is then patched or triaged into `ignore` with
  a per-entry justification). `make scan IMAGE=<ref>` runs
  `grype <ref> -c .grype/policy.yaml`.
- **SBOM.** Pinned **syft** CycloneDX JSON (`make sbom IMAGE=<ref> OUTPUT=...`),
  retained as a workflow artifact and fed to the cosign attest gate. syft scans
  the runner's default platform (amd64 on `ubuntu-24.04`); a per-arch SBOM is a
  future refinement, WU4 ships a single SBOM per the plan's acceptance criterion.
- **Signing — keyless cosign.** `make sign REF=<ref> SBOM=...` runs
  `cosign sign --yes <ref>` then `cosign attest --yes --predicate <sbom> --type
  cyclonedx <ref>` per registry ref (3×), using the **pinned cosign** from
  `tools.yaml`. Keyless is default in cosign v3; cosign auto-detects GitHub OIDC
  from the runner when `id-token: write` is granted. The digest-pinned ref
  (`repo@sha256:...`) is the canonical signing target.
- **Registry parity.** `make parity` resolves each tag-form ref to its raw
  manifest via `docker buildx imagetools inspect --raw` and asserts the three raw
  manifests are byte-identical (the manifest digest IS sha256 of the raw
  manifest, so byte-identity implies digest-identity). Version-independent — no
  dependence on buildx Go-template field names — and fails closed.
- **ARM test posture for 18-3.6.** Per the WU2 record, the apt-based `18-3.6`
  image has no fragile ARM source-build test surface, so there is nothing to
  relax into a warn here. The runnable extension smoke (run in `ci.yml` /
  `smoke-*`) fully gates; the publish pipeline does not re-run it (the image
  bytes it publishes are the ones the PR tier already smoke-tested).
- **Verification posture for this WU.** A tag-triggered publish workflow does not
  fire on a PR, and no tag is cut here (WU5). "Done" for WU4 is therefore:
  `make validate` green (actionlint + Zizmor + hadolint + shellcheck + shfmt +
  gitleaks + markdownlint over the new YAML and scripts); `make presubmit` green
  (nothing regressed); the four publish-gate targets are syntactically valid GNU
  Make and resolve their pinned tools (`make tools-audit` shows them cached).
  End-to-end publish verification is deferred to WU5's tag cut.

## Release procedure (compound-tag release)

This is the operator runbook for cutting a `convoy-postgres` compound-tag
release. Releases are an **explicit operator decision** (TOOLSPEC): no automation
cuts or publishes a tag. The pipeline this procedure drives — multi-arch build,
triple-registry push, and the four publish gates — is designed and documented in
the [WU4 section](#wu4-pr-validation--signed-multi-registry-multi-arch-publish-pipeline);
this section tells the operator how to drive it and does not re-explain the
pipeline design. The first release cut by this procedure was the **Phase 1
pivot** (WU5/ENG-521): the compound tag `18-3.6-pgmq1.10`, now published and
pinned to by the WU6/WU7/WU8 consumers.

### Tag scheme

The compound tag is `<PG-major>-<postgis>-<pgmq>`, mirroring the upstream
`postgis/docker-postgis` version-directory scheme with the pgmq suffix
recorded in the [WU3 section](#wu3-pgmq-bundling-into-the-image). The first cut:

```bash
18-3.6-pgmq1.10
```

(PG 18, PostGIS 3.6, pgmq 1.10.) The workflow trigger glob
`on.push.tags: ['18-*-*']` (`publish.yml`) requires **two dashes** after `18-`,
so it matches `18-3.6-pgmq1.10` but not a plain upstream-style `18-3.6` tag — a
mistagged `18-3.6` will not fire the pipeline.

**No floating `latest` is ever published.** `docker/metadata-action` emits the
tag with **`type=raw,value=<tag>`** (not `type=ref,event=tag`) plus
**`flavor: latest=false`**. `type=ref` does not behave correctly across a
multi-registry push — GHCR's distinct naming in particular — so the tag value is
given explicitly per image. A run-time assertion in `publish.yml` still fails the
job if any `latest` tag is emitted. Consumers always pin an exact compound tag.

### Pre-flight (recommended)

Before tagging, surface the Grype CVE set locally so the publish scan is clean.
The publish gate (`.grype/policy.yaml`) enforces `fail-on-severity: high` against
an `ignore:` accept-list. The first release (WU5) populated that list with the
base image's gating CVEs, each with a dated justification — enough for a clean
CI today, but known container-security debt tracked in ENG-578 (the long-term
fix is a different base image derivation). Re-scan on every base bump and prune
remediated entries.

```bash
make smoke-native   # builds AND RUNS the product image on the daemon-native arch
# smoke-native tags the local image convoy-postgres:18-3.6-smoke-<arch>
make scan IMAGE=convoy-postgres:18-3.6-smoke-<arch>   # grype -c .grype/policy.yaml
```

`<arch>` is the daemon's native arch (`arm64` on Apple Silicon, `amd64` on x86
Linux). Any vulnerability at or above `high` not on the `ignore` list trips the
gate. For each gating finding, either **patch** it (base bump or package pin) or
**triage** it into `.grype/policy.yaml`'s `ignore:` with a dated inline
justification (the file documents this exact entry shape) — **before** the tag
is cut.

### Cut the tag

The tag is cut on `main` (never a feature branch; see [Branch model](#branch-model)).
From an up-to-date `main`:

```bash
git checkout main && git pull --ff-only
git tag -a 18-3.6-pgmq1.10 -m "convoy-postgres 18-3.6-pgmq1.10 (PG18 + PostGIS 3.6 + pgmq 1.10)"
git push origin 18-3.6-pgmq1.10
```

The `git push origin <tag>` is what fires the publish pipeline.

### What fires

The tag push triggers `.github/workflows/publish.yml`, guarded to
`github.repository == 'convoyai-public/docker-postgis'` (a tag on any other fork
has no org secrets and must never publish). The pipeline, in order:

1. **Multi-arch build** of `dockerfiles/18-3.6.dockerfile` (the WU3 product
   image) for `linux/amd64,linux/arm64` via QEMU + buildx, `push: true`.
2. **Triple-registry push** of the compound tag (see Published references).
3. **No-`latest` assertion** — fails the job before any gate runs if
   metadata-action emitted a `latest`.
4. **Four sequential publish gates**, each failing the job on its regression:
   Grype policy scan → Syft CycloneDX SBOM → keyless cosign sign + SBOM attest
   (once per registry, three times) → cross-registry manifest parity.

The design rationale for each gate is in the
[WU4 section](#wu4-pr-validation--signed-multi-registry-multi-arch-publish-pipeline).
`workflow_dispatch` is an alternate trigger (manual run from the Actions UI),
useful for re-running the gates against an already-pushed tag without re-pushing
it.

### Published references

The published **image name is `convoy-postgres`** across all three registries;
the three registries are distinct prefixes over that same image name. Concrete
pull refs for `18-3.6-pgmq1.10`:

| Registry | Pull reference |
| --- | --- |
| GAR (primary) | `us-central1-docker.pkg.dev/containerhosting/convoy/convoy-postgres:18-3.6-pgmq1.10` |
| Docker Hub | `${DH_REPO_MARK}/convoy-postgres:18-3.6-pgmq1.10` |
| GHCR | `ghcr.io/convoyai-public/convoy-postgres:18-3.6-pgmq1.10` |

`GHA_GAR_HOST`/`GHA_GAR_PATH` and `DH_REPO_MARK` are provisioned as
`convoyai-public` org variables; this document names the variables rather than
fabricating the Docker Hub namespace. Reconciliation: the Linear AC's literal
`docker pull convoyai/convoy-postgres:...` uses the **logical** image name; the
concrete Docker Hub pull ref uses the `${DH_REPO_MARK}` namespace, **not**
`convoyai`.

### Verify acceptance

After a green publish run, verify against each of the three refs above.

**Multi-arch manifest + per-arch digests** — the manifest list and each
platform's digest (the parity refs; the publish-parity gate already asserted the
three registries resolve to byte-identical raw manifests):

```bash
docker buildx imagetools inspect <ref>   # any one of the three refs above
```

**Pull each arch:**

```bash
docker pull --platform linux/amd64 <ref>
docker pull --platform linux/arm64 <ref>
```

**PostGIS + pgmq present** — matches the WU3 acceptance shape. The authoritative
runnable test is `scripts/smoke-run.sh` (exercised by `make smoke-multiarch`).
For an operator spot-check of a pulled image, run a container and confirm the
extensions; postgis is auto-created by the image's initdb script, so verify its
presence and create pgmq:

```bash
docker run -d --name cp-verify -e POSTGRES_PASSWORD=x <ref>
# Gate on TCP readiness — NOT bare pg_isready. The default resolves to the temp
# init server's Unix socket and returns a false "ready" before the initdb script
# has created postgis (the readiness race scripts/smoke-run.sh guards against):
until docker exec cp-verify pg_isready -h 127.0.0.1 -p 5432 -U postgres >/dev/null 2>&1; do sleep 1; done
docker exec cp-verify psql -U postgres -c \
  "SELECT extname FROM pg_extension WHERE extname IN ('postgis','pgmq');"
docker exec cp-verify psql -U postgres -c "CREATE EXTENSION pgmq;"
```

**cosign verify (keyless, GitHub OIDC)**, per registry ref. The signing job runs
with `id-token: write`, so the signature certificate carries the GitHub OIDC
`job_workflow_ref` for this workflow at this exact tag:

```bash
cosign verify <ref> \
  --certificate-identity "https://github.com/convoyai-public/docker-postgis/.github/workflows/publish.yml@refs/tags/18-3.6-pgmq1.10" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
```

To match every tag from this workflow, swap `--certificate-identity` for
`--certificate-identity-regexp` and drop the `@refs/tags/<tag>` suffix. The SBOM
attestation (produced by the `cosign attest` gate) verifies with the same
identity/issuer:

```bash
cosign verify-attestation --type cyclonedx <ref> \
  --certificate-identity "https://github.com/convoyai-public/docker-postgis/.github/workflows/publish.yml@refs/tags/18-3.6-pgmq1.10" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
```

**No `latest`:** confirm no `latest` tag exists in each registry (the workflow's
run-time assertion already enforces it at publish time; this is the operator
double-check).

### Record canonical pin evidence

After a green publish, record the canonical pin reference consumers pin to — as a
**GitHub Release** attached to the tag and mirrored in a Linear ENG-521 comment.
This is the single source WU7 (core-platform) and WU8 (data-platform) pin to. It
captures:

- the compound tag (`18-3.6-pgmq1.10`);
- the three registry pull refs (see Published references);
- the multi-arch manifest-list digest (the `sha256:...` from
  `docker buildx imagetools inspect`, identical across the three registries);
- the per-arch digests (`linux/amd64`, `linux/arm64`) from the same inspect;
- the `cosign verify` command (certificate identity + issuer) for the release;
- the SBOM — attach the `sbom-cyclonedx-18-3.6-pgmq1.10` workflow artifact's
  JSON to this Release (workflow artifacts expire; the Release is the durable
  home for the canonical evidence) — and the build provenance attestation.

### Grype triage and re-cut

If the publish scan trips, the publish job fails before signing. Recover:

1. Read the Grype output from the failed publish run (the gate prints the gating
   vulnerabilities).
2. For each gating finding, either **patch** it (base bump or package pin) or add
   a dated, justified entry to `.grype/policy.yaml`'s `ignore:` (the file
   documents the exact entry shape).
3. Land that change on `main` via the open WU5 PR; the static gates re-run on
   the PR.
4. Re-fire publish cleanly. Because WU5 is the **first** tag and no consumer has
   pinned it yet, delete and re-create the tag on the new `main` HEAD:

   ```bash
   git push --delete origin 18-3.6-pgmq1.10
   git tag -d 18-3.6-pgmq1.10
   git checkout main && git pull --ff-only
   git tag -a 18-3.6-pgmq1.10 -m "convoy-postgres 18-3.6-pgmq1.10 (PG18 + PostGIS 3.6 + pgmq 1.10)"
   git push origin 18-3.6-pgmq1.10
   ```

This delete-and-recreate is acceptable **only** for the first, pre-consumer tag.
Later releases must never rewrite a published tag — once WU7/WU8 pin a tag, its
digest is immutable, and a fix ships as the next compound tag.
