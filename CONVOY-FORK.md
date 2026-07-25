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
| `smoke` | Build the **unmodified upstream image** for one representative version (`18-3.6`) natively, proving the baseline builds. |
| `vendor-audit` | Report upstream commits on `upstream/master` not present on `convoy-vendor`. |
| `presubmit` | Local equivalent of the fast PR tier: `format` + `validate` + `generated-check` + `smoke`. |

Publish, sign, and multi-arch targets are **WU4** and are intentionally absent
here.

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
