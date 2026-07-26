<!-- CONVOY-FORK-DOC -->
# Convoy fork of `postgis/docker-postgis`

This repository is a **true fork** of the upstream
[`postgis/docker-postgis`](https://github.com/postgis/docker-postgis) project.
Full upstream history is preserved. Upstream remains the source of truth for the
generated Dockerfiles, the `update.sh` generator, and the per-version image
recipes; this fork layers Convoy's packaging, validation, and release concerns
on top without reimplementing upstream's work.

The **published image name is `convoy-postgres`**. The publishing org (GHCR
primary + Docker Hub mirror), dual-registry parity, SBOM/provenance, and cosign
signing are established in WU4 of the convoy-deploy Phase 1 plan and are
**out of scope** for this work unit (WU1). WU1 only stands up the repo substrate,
the local validation/tooling scaffold, and thin CI.

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

Local **multi-arch assembly** (`build-multiarch`) and **runnable per-arch smoke**
(`smoke-*`) are WU2. **Publish, sign, and registry** targets remain **WU4** and
are intentionally absent here; `build-multiarch` writes only a local OCI tarball.

## Validation scoping (important)

The static gates guard **Convoy-owned inputs only**:

- ShellCheck / shfmt lint `scripts/*.sh` (Convoy's thin Bash 5 helpers).
- Hadolint lints Convoy-authored Dockerfiles (none in WU1).
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
