# Packages the `router` extension service (BIRD-wrapping BGP/OSPF daemon,
# ../talos-extensions) into a Talos system extension image, via siderolabs/extensions'
# own pkg.yaml/bldr pipeline. No kernel module - pure userspace, so unlike
# ../talos-awg-extension this repo has no dependency on ../talos-kernel at all.
#
# One of five repos in a split pipeline - see README, "This is one of five repos".
#
# Needs Docker + `docker buildx` (siderolabs' real `bldr` toolchain, a custom BuildKit
# frontend podman/buildah can't run).
#
# build/ is disposable: `make distclean && make extension TARGET_ARCH=<arch>` reproduces
# it from versions.env and patches/ alone.

include versions.env

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

_GOALS := $(or $(MAKECMDGOALS),$(.DEFAULT_GOAL))
ifeq ($(TARGET_ARCH),)
  ifneq ($(filter-out distclean help checkout-extensions check-daemons,$(_GOALS)),)
    $(error TARGET_ARCH not set - pass TARGET_ARCH=amd64 or TARGET_ARCH=arm64)
  endif
endif
ifeq ($(RELEASE_TAG),)
  ifneq ($(filter-out distclean help checkout-extensions check-daemons daemons,$(_GOALS)),)
    $(error RELEASE_TAG not set - pass RELEASE_TAG=v0.1.0+bird$(BIRD_VERSION), the git tag this build is released under)
  endif
endif

BUILD_DIR      := build
EXTENSIONS_DIR := $(BUILD_DIR)/extensions

# The `router` extension-service daemon lives in a sibling repo, not here - this repo
# only cross-compiles it and hands the binary to the siderolabs/extensions checkout for
# packaging. See that repo's README for what it does.
DAEMONS_DIR              := ../talos-extensions
DAEMON_RUST_TARGET_amd64 := x86_64-unknown-linux-musl
DAEMON_RUST_TARGET_arm64 := aarch64-unknown-linux-musl
DAEMON_RUST_TARGET       := $(DAEMON_RUST_TARGET_$(TARGET_ARCH))
DAEMONS_SHA              := $(shell git -C $(DAEMONS_DIR) rev-parse --short HEAD 2>/dev/null || echo unknown)

# Registry tag follows ../bird's own convention: the git release tag *is* the image tag
# (`+` swapped for `-`, since OCI tags can't contain `+`) - RELEASE_TAG is required, not
# derived from versions.env pins, so a rebuild against unchanged pins still needs an
# explicit new release to publish under (the old DAEMONS_SHA-keyed scheme's staleness fix -
# re-pushing under an unchanged tag has been observed, in ../talos-awg-extension, to not
# reliably reach a node on `talosctl upgrade` - is now just "cut a new release").
RELEASE_TAG_SAFE := $(subst +,-,$(RELEASE_TAG))
EXT_IMAGE := $(IMAGE):$(RELEASE_TAG_SAFE)-$(TARGET_ARCH)

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: print-config
print-config: ## Show the resolved pins, arch and image names.
	@echo "talos            : $(TALOS_VERSION)"
	@echo "extensions ref   : $(UPSTREAM_EXTENSIONS_REF)"
	@echo "daemons ref      : $(DAEMONS_REF) (sibling at $(DAEMONS_SHA))"
	@echo "bird version     : $(BIRD_VERSION)"
	@echo "host arch        : $$(uname -m)"
	@echo "target arch      : $(TARGET_ARCH)"
	@echo "release tag      : $(RELEASE_TAG)"
	@echo "extension image  : $(EXT_IMAGE)"

.PHONY: preflight
preflight: ## Check this machine can run the build.
	@fail=0; \
	for t in docker git curl; do command -v $$t >/dev/null || { echo "MISSING: $$t"; fail=1; }; done; \
	docker buildx version >/dev/null 2>&1 || { echo "MISSING: docker buildx"; fail=1; }; \
	docker version >/dev/null 2>&1 || { echo "docker daemon not reachable (permission denied or not running)"; fail=1; }; \
	command -v cargo >/dev/null || { echo "MISSING: cargo"; fail=1; }; \
	command -v cargo-zigbuild >/dev/null || { echo "MISSING: cargo-zigbuild (cargo install cargo-zigbuild --locked)"; fail=1; }; \
	[ -d $(DAEMONS_DIR) ] || { echo "MISSING: sibling checkout $(DAEMONS_DIR)"; fail=1; }; \
	echo "host $$(uname -m)"; \
	[ $$fail -eq 0 ] && echo "preflight OK" || exit 1

##@ Build

$(BUILD_DIR):
	@mkdir -p $@

.PHONY: checkout-extensions
checkout-extensions: | $(BUILD_DIR) ## Fetch siderolabs/extensions at the pinned ref, overlay patches/extensions/.
	@if [ ! -d "$(EXTENSIONS_DIR)/.git" ]; then \
	  echo "==> cloning siderolabs/extensions"; \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/extensions.git $(EXTENSIONS_DIR); \
	fi
	@git -C $(EXTENSIONS_DIR) fetch --quiet --filter=blob:none origin $(UPSTREAM_EXTENSIONS_REF) 2>/dev/null || git -C $(EXTENSIONS_DIR) fetch --quiet origin
	@git -C $(EXTENSIONS_DIR) checkout --quiet --force --detach $(UPSTREAM_EXTENSIONS_REF)
	@rm -rf $(EXTENSIONS_DIR)/router
	@cp -r patches/extensions/router $(EXTENSIONS_DIR)/router

.PHONY: check-daemons
check-daemons: ## Assert ../talos-extensions is checked out at DAEMONS_REF.
	@git -C $(DAEMONS_DIR) rev-parse --git-dir >/dev/null 2>&1 \
	  || { echo "not a git checkout: $(DAEMONS_DIR)"; exit 1; }
	@want=$$(git -C $(DAEMONS_DIR) rev-parse --verify --quiet 'refs/tags/$(DAEMONS_REF)^{commit}' || true); \
	if [ -z "$$want" ]; then \
	  echo "tag $(DAEMONS_REF) not in $(DAEMONS_DIR) - fetch its tags"; \
	  exit 1; \
	fi; \
	have=$$(git -C $(DAEMONS_DIR) rev-parse --verify HEAD); \
	if [ "$$have" = "$$want" ]; then \
	  echo "talos-extensions at $(DAEMONS_REF)"; \
	else \
	  echo "MISMATCH: $(DAEMONS_DIR) is at $$have, DAEMONS_REF $(DAEMONS_REF) is $$want"; \
	  echo "the daemon baked into the extension would not be the one this release names"; \
	  exit 1; \
	fi

.PHONY: daemons
daemons: check-daemons ## Cross-compile the router extension-service daemon (../talos-extensions).
	@command -v cargo-zigbuild >/dev/null || { echo "MISSING: cargo-zigbuild"; exit 1; }
	@rustup target add $(DAEMON_RUST_TARGET) >/dev/null 2>&1 || true
	@echo "==> cross-compiling router for $(TARGET_ARCH) ($(DAEMON_RUST_TARGET))"
	@(cd $(DAEMONS_DIR) && cargo zigbuild --release --target $(DAEMON_RUST_TARGET) -p router)

# Field order here is load-bearing, not stylistic: siderolabs' own extensions-validator
# (cmd/extensions-validator/cmd/validate.go) only accepts a handful of exact version
# shapes via regex, and the one that fits a hash + a Talos version + extra free-form
# text is `^([0-9a-f]+)-v(\d+\.\d+\.\d+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?)...$` - a
# lowercase-hex token, then literal "-v", then TALOS_VERSION's own X.Y.Z, with anything
# else (BIRD_VERSION here) only valid as a further "-"-prefixed suffix *after* that,
# folded into the semver prerelease part. DAEMONS_SHA has to come first for exactly this
# reason: BIRD_VERSION-TALOS_VERSION-DAEMONS_SHA and bird+BIRD_VERSION-TALOS_VERSION-DAEMONS_SHA
# are both rejected with "invalid version format". talos-awg-extension's own EXT_VERSION
# satisfies the same regex by luck of field order, not by design there either.
EXT_VERSION := $(DAEMONS_SHA)-$(TALOS_VERSION)-bird$(BIRD_VERSION)

BIRD_ARGS := --build-arg=BIRD_IMAGE=$(BIRD_IMAGE) --build-arg=BIRD_IMAGE_TAG=$(BIRD_IMAGE_TAG)

.PHONY: extension
extension: daemons checkout-extensions ## Package bird/birdc + the router daemon into a Talos system extension image (bldr).
	@cp $(DAEMONS_DIR)/target/$(DAEMON_RUST_TARGET)/release/router $(EXTENSIONS_DIR)/router/router-bin
	@cp $(DAEMONS_DIR)/extension-services/router.yaml $(EXTENSIONS_DIR)/router/router-service.yaml
	@echo "==> building $(EXT_IMAGE) ($(TARGET_ARCH))"
	@$(MAKE) -C $(EXTENSIONS_DIR) docker-router PLATFORM=linux/$(TARGET_ARCH) \
	  TARGET_ARGS="--tag=$(EXT_IMAGE) --push=true $(BIRD_ARGS) --build-arg=VERSION=$(EXT_VERSION)"
	@echo
	@echo "published: $(EXT_IMAGE)"
	@echo "talos-installer needs this ref to bundle it into an installer"

.PHONY: all
all: preflight extension ## Everything: daemons -> extension image.

##@ Maintenance

.PHONY: clean
clean: ## No separate build output to drop - kept for symmetry with the other repos.
	@true

.PHONY: distclean
distclean: ## Drop everything, including the pinned checkout.
	@rm -rf $(BUILD_DIR)
