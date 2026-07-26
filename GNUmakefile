# Convoy fork of postgis/docker-postgis — GNU Make entry point.
#
# GNU Make prefers GNUmakefile over Makefile, so this becomes the front door
# WITHOUT editing upstream's Makefile (keeping vendor merges clean). It
# -include's the upstream Makefile so upstream's build/test/push targets remain
# available; it then layers the Convoy targets below. See CONVOY-FORK.md.
#
# Policy: convoy-deploy specs/TOOLSPEC.md. Requires GNU Make 4.4+. On macOS use
# Homebrew `gmake` (`brew install make`); the BSD system `/usr/bin/make` is
# unsupported.

# --- Make version guard (TOOLSPEC: fail fast on < 4.4 / non-GNU) ---------------
ifeq ($(filter 4.%,$(MAKE_VERSION)),)
$(error GNU Make 4.4+ required (found MAKE_VERSION='$(MAKE_VERSION)'). \
On macOS install Homebrew make (`brew install make`) and invoke as `gmake`; \
the BSD system `/usr/bin/make` is unsupported. See CONVOY-FORK.md.)
endif
# Compare MAKE_VERSION (e.g. 4.4.1) against 4.4 using version sort.
_make_min_ok := $(shell \
	printf '%s\n' '4.4' '$(MAKE_VERSION)' | sort -V | head -1 | grep -q '^4\.4$$' && echo yes)
ifneq ($(_make_min_ok),yes)
$(error GNU Make 4.4+ required (found $(MAKE_VERSION)). \
On macOS use Homebrew `gmake`, not the BSD system `make`. See CONVOY-FORK.md.)
endif

.DEFAULT_GOAL := help

# Recipes use Bash 5 constructs ([[ ]], command -v); force Bash (TOOLSPEC).
SHELL := bash
.SHELLFLAGS := -o pipefail -c

# Reuse upstream targets (build/test/push/all/update) untouched.
-include Makefile

ROOT        := $(CURDIR)
HOST        := $(shell scripts/host.sh)
TOOLS_CACHE := $(ROOT)/.tools/cache/$(HOST)
DOCKER      ?= docker

# Pinned binary tools managed by tools/tools.yaml. markdownlint-cli2 is OCI-based.
BINARY_TOOLS := actionlint hadolint shellcheck shfmt gitleaks zizmor syft grype cosign
OCI_TOOLS    := markdownlint-cli2

# Convoy-owned validation inputs (upstream-owned files are excluded; see CONVOY-FORK.md).
SHELL_SCRIPTS  := $(wildcard scripts/*.sh)
WORKFLOWS      := $(wildcard .github/workflows/*.yml)
CONVOY_DOCKERFILES := $(wildcard dockerfiles/*.dockerfile)  # none in WU1
MARKDOWN_FILES := CONVOY-FORK.md

# Resolve a tool: pinned cache first, then PATH (tools-resolve.sh warns on fallback).
resolve = $(shell scripts/tools-resolve.sh $(1))

.PHONY: help tools tools-audit oci-tools \
        validate format format-apply lint lint-shellcheck lint-dockerfile \
        lint-actionlint lint-zizmor lint-gitleaks lint-markdownlint \
        generated-check smoke smoke-arm64 smoke-amd64 smoke-multiarch smoke-native \
        build-multiarch vendor-audit presubmit

help: ## Show this help
	@echo "Convoy fork of postgis/docker-postgis — targets"
	@echo "  (upstream targets build/test/push/all/update are also available via -include Makefile)"
	@echo ""
	@echo "Local entry point: 'gmake' on macOS (GNU Make 4.4+), 'make' on Linux."
	@echo "Pinned tools cache: make tools   (resolves .tools/cache/<host> from tools/tools.yaml)"
	@echo ""
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-20s %s\n",$$1,$$2}'
	@echo ""
	@echo "Static gates scope to Convoy-owned files (CONVOY-FORK.md \"Validation scoping\")."

tools: $(foreach t,$(BINARY_TOOLS),tools-$(t)) oci-tools ## Populate the pinned tool cache for all tools

oci-tools: $(foreach t,$(OCI_TOOLS),tools-$(t)) ## Preload pinned OCI tool images

.PHONY: $(foreach t,$(BINARY_TOOLS) $(OCI_TOOLS),tools-$(t))
$(foreach t,$(BINARY_TOOLS) $(OCI_TOOLS),tools-$(t)): tools-%: scripts/tools-sync.sh tools/tools.yaml
	@scripts/tools-sync.sh $*

tools-audit: ## Report tool-cache state vs the manifest
	@echo "host: $(HOST)"
	@echo "cache: $(TOOLS_CACHE)"
	@for t in $(BINARY_TOOLS); do \
		if [[ -x "$(TOOLS_CACHE)/$$t" ]]; then echo "  [cached] $$t"; \
		elif command -v "$$t" >/dev/null 2>&1; then echo "  [PATH]   $$t ($$(command -v $$t)) — run 'make tools' to pin"; \
		else echo "  [MISSING] $$t"; fi; \
	done
	@for t in $(OCI_TOOLS); do \
		img=$$(scripts/manifest-get.sh $$t image); \
		if docker image inspect "$$img" >/dev/null 2>&1; then echo "  [oci]    $$t ($$img)"; \
		else echo "  [oci?]   $$t ($$img) — not present; run 'make tools'"; fi; \
	done

validate: format lint-actionlint lint-zizmor lint-shellcheck lint-dockerfile lint-gitleaks lint-markdownlint generated-check ## Run the full static-validation suite over Convoy-owned inputs (shfmt + lints + generated-check)

format: ## Check shell formatting (shfmt -d) on Convoy scripts
	@echo "format: shfmt -d over scripts/*.sh"
	@if [[ -z "$(SHELL_SCRIPTS)" ]]; then echo "  (no Convoy shell scripts)"; else \
		$(call resolve,shfmt) -d $(SHELL_SCRIPTS); fi

format-apply: ## Apply shell formatting (shfmt -w) to Convoy scripts
	@if [[ -n "$(SHELL_SCRIPTS)" ]]; then $(call resolve,shfmt) -w $(SHELL_SCRIPTS); fi

lint: lint-shellcheck lint-dockerfile ## Lint (shellcheck + hadolint) over Convoy-owned inputs

lint-shellcheck:
	@echo "lint: shellcheck over scripts/*.sh"
	@if [[ -z "$(SHELL_SCRIPTS)" ]]; then echo "  (no Convoy shell scripts)"; else \
		$(call resolve,shellcheck) $(SHELL_SCRIPTS); fi

lint-dockerfile:
	@echo "lint: hadolint over Convoy-authored Dockerfiles"
	@files=$$(ls dockerfiles/*.dockerfile 2>/dev/null); \
	if [[ -z "$$files" ]]; then \
		echo "  (no Convoy-authored Dockerfiles in WU1; upstream Dockerfiles are excluded)"; \
	else $(call resolve,hadolint) $$files; fi

lint-actionlint:
	@echo "lint: actionlint over .github/workflows/*.yml"
	@$(call resolve,actionlint) -color

lint-zizmor:
	@echo "lint: zizmor over .github/workflows"
	@$(call resolve,zizmor) --collect=workflows .github/workflows

lint-gitleaks:
	@echo "lint: gitleaks over the repository tree"
	@$(call resolve,gitleaks) detect --source . --no-banner

lint-markdownlint:
	@echo "lint: markdownlint-cli2 (OCI) over $(MARKDOWN_FILES)"
	@docker run --rm -v "$(ROOT):/workdir" -w /workdir \
		$$(scripts/manifest-get.sh markdownlint-cli2 image) $(MARKDOWN_FILES)

# Committed generated outputs to drift-check. Register paths here as they are added.
GENERATED :=
generated-check: ## Reject drift in committed generated output (none registered in WU1)
	@echo "generated-check: $(if $(GENERATED),checking $(GENERATED),no committed generated outputs registered yet (WU1))"

# Build the UNMODIFIED upstream image for one representative version, natively,
# to prove the pre-patch baseline builds. Native arch only. (publish/sign/multi-arch = WU4)
SMOKE_VERSION := 18-3.6
SMOKE_REPO    ?= postgis
SMOKE_IMAGE   ?= postgis
smoke: ## Build the unmodified upstream 18-3.6 image natively (baseline; build-only)
	@echo "smoke: building unmodified upstream $(SMOKE_REPO)/$(SMOKE_IMAGE):$(SMOKE_VERSION) (native arch)..."
	@$(DOCKER) build --pull -t $(SMOKE_REPO)/$(SMOKE_IMAGE):$(SMOKE_VERSION) $(SMOKE_VERSION)
	@echo "smoke: built $(SMOKE_REPO)/$(SMOKE_IMAGE):$(SMOKE_VERSION)"

# --- WU2: ARM build enablement -------------------------------------------------
# Per-arch RUNNABLE smokes (buildx --load + run + CREATE EXTENSION postgis + a
# spatial op). These prove the image is runnable on each arch, not merely
# buildable — the heart of WU2. scripts/smoke-run.sh is the executable AC proof.
# Buildx is a TOOLSPEC host prerequisite; no new toolchain. Publish/sign/registry
# stays WU4; build-multiarch only assembles a local manifest, it never publishes.
# WU3: the runnable targets now build the CONVOY PRODUCT Dockerfile
# (dockerfiles/18-3.6.dockerfile, which layers pgmq on the upstream PostGIS
# layer) from the repo-root context, and scripts/smoke-run.sh adds a pgmq
# create + queue round-trip assertion. The build-only `smoke` baseline above
# STAYS on the UNMODIFIED upstream image (context $(SMOKE_VERSION), default
# Dockerfile) so it keeps proving the upstream baseline builds — the WU1 intent.
SMOKE_DOCKERFILE := dockerfiles/18-3.6.dockerfile
SMOKE_CTX_ROOT   := .

smoke-arm64: ## Runnable smoke: build + run the product image on linux/arm64
	@scripts/smoke-run.sh arm64 $(SMOKE_CTX_ROOT) $(SMOKE_DOCKERFILE)

smoke-amd64: ## Runnable smoke: build + run the product image on linux/amd64 (emulated on Apple Silicon)
	@scripts/smoke-run.sh amd64 $(SMOKE_CTX_ROOT) $(SMOKE_DOCKERFILE)

smoke-multiarch: smoke-arm64 smoke-amd64 ## Runnable smoke on BOTH arches (amd64 emulated on Apple Silicon)

# Runnable smoke for the Docker daemon's native arch (fast everywhere; no
# emulation). Detected from `docker info` so it is correct on Apple Silicon
# (arm64) and on x86 Linux/CI (amd64).
smoke-native: ## Runnable smoke for the daemon-native arch (fast; used by presubmit)
	@arch=$$(docker info --format '{{.Architecture}}' \
		| sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/'); \
	echo "smoke-native: daemon arch=$$arch"; \
	scripts/smoke-run.sh "$$arch" $(SMOKE_CTX_ROOT) $(SMOKE_DOCKERFILE)

# Assemble a local multi-arch manifest (linux/amd64,linux/arm64) to an OCI
# layout tarball WITHOUT publishing. Proves both arches build into one manifest.
# --load cannot carry multiple platforms, so multi-arch uses --output type=oci.
MULTIARCH_TARBALL := build/$(SMOKE_REPO)-$(SMOKE_VERSION)-multiarch.oci.tar
build-multiarch: ## Assemble a local multi-arch manifest (amd64+arm64) without publishing
	@mkdir -p $(dir $(MULTIARCH_TARBALL))
	@echo "build-multiarch: assembling linux/amd64,linux/arm64 manifest -> $(MULTIARCH_TARBALL)"
	@$(DOCKER) buildx build --platform linux/amd64,linux/arm64 \
		-f $(SMOKE_DOCKERFILE) \
		--output type=oci,dest=$(MULTIARCH_TARBALL) $(SMOKE_CTX_ROOT)
	@echo "build-multiarch: manifest assembled at $(MULTIARCH_TARBALL)"
	@# Positive assertion: the assembled OCI tarball's manifest-list blob must
	@# carry BOTH linux/amd64 and linux/arm64. imagetools inspect is registry-only
	@# and cannot read a local OCI tarball, so parse the layout we wrote: the
	@# index.json image-index descriptor digest -> blobs/sha256/<hex> manifest list,
	@# then grep each platform's architecture. No new toolchain (tar/sed/grep only).
	@idx=$$(tar -xOf $(MULTIARCH_TARBALL) index.json); \
	digest=$$(printf '%s\n' "$$idx" | sed -n 's/.*"digest":"sha256:\([0-9a-f]\{64\}\)".*/\1/p' | head -n1); \
	manifest=$$(tar -xOf $(MULTIARCH_TARBALL) "blobs/sha256/$$digest"); \
	for arch in amd64 arm64; do \
		printf '%s\n' "$$manifest" | grep -Eq "\"architecture\":[[:space:]]*\"$$arch\"" || { \
			echo "build-multiarch: assembled manifest missing architecture $$arch" >&2; \
			echo "---- manifest-list blob (blobs/sha256/$$digest) ----" >&2; \
			printf '%s\n' "$$manifest" >&2; \
			exit 1; \
		}; \
	done; \
	echo "[build-multiarch] manifest carries linux/amd64 + linux/arm64"

vendor-audit: ## Report upstream commits not yet on convoy-vendor
	@scripts/vendor-audit.sh

# Local equivalent of the fast PR tier. validate already includes format (shfmt),
# the lint-* suite, and generated-check; smoke-native builds AND RUNS the
# upstream 18-3.6 image on the daemon-native arch (fast; no emulation), proving
# the baseline is runnable, not merely buildable.
presubmit: validate smoke-native ## validate (shfmt + lints + generated-check) + native runnable smoke
	@echo "presubmit: all Convoy gates green."
