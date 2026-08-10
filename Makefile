# Packages the `router` extension service (BIRD-wrapping BGP/OSPF daemon,
# ../talos-extensions) into a Talos system extension image, via siderolabs/extensions'
# own pkg.yaml/bldr pipeline. No kernel module - pure userspace, so unlike
# ../talos-awg-extension this repo has no dependency on ../talos-kernel at all.
#
# One of four repos in a split pipeline - see README, "This is one of four repos".
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
  ifneq ($(filter-out distclean help hashes checkout-extensions,$(_GOALS)),)
    $(error TARGET_ARCH not set - pass TARGET_ARCH=amd64 or TARGET_ARCH=arm64)
  endif
endif

BUILD_DIR      := build
EXTENSIONS_DIR := $(BUILD_DIR)/extensions

# The `router` extension-service daemon lives in a sibling repo, not here - this repo
# only cross-compiles it and hands the binary to the siderolabs/extensions checkout for
# packaging. See that repo's README/AGENTS.md for what it does.
AGENTS_DIR              := ../talos-extensions
AGENT_RUST_TARGET_amd64 := x86_64-unknown-linux-musl
AGENT_RUST_TARGET_arm64 := aarch64-unknown-linux-musl
AGENT_RUST_TARGET       := $(AGENT_RUST_TARGET_$(TARGET_ARCH))
AGENTS_SHA              := $(shell git -C $(AGENTS_DIR) rev-parse --short HEAD 2>/dev/null || echo unknown)

# Tag includes AGENTS_SHA (../talos-extensions' own commit) so a rebuild after fixing
# something there always gets a genuinely new tag - re-pushing under an unchanged tag has
# been observed (in ../talos-awg-extension) to not reliably reach a node on `talosctl
# upgrade`. See that repo's AGENTS.md for the specifics.
EXT_IMAGE := $(IMAGE):extension-$(TALOS_VERSION)-router-$(AGENTS_SHA)-$(TARGET_ARCH)

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
	@echo "bird version     : $(BIRD_VERSION)"
	@echo "host arch        : $$(uname -m)"
	@echo "target arch      : $(TARGET_ARCH)"
	@echo "extension image  : $(EXT_IMAGE)"

.PHONY: preflight
preflight: ## Check this machine can run the build.
	@fail=0; \
	for t in docker git curl; do command -v $$t >/dev/null || { echo "MISSING: $$t"; fail=1; }; done; \
	docker buildx version >/dev/null 2>&1 || { echo "MISSING: docker buildx"; fail=1; }; \
	docker version >/dev/null 2>&1 || { echo "docker daemon not reachable (permission denied or not running)"; fail=1; }; \
	command -v cargo >/dev/null || { echo "MISSING: cargo"; fail=1; }; \
	command -v cargo-zigbuild >/dev/null || { echo "MISSING: cargo-zigbuild (cargo install cargo-zigbuild --locked)"; fail=1; }; \
	[ -d $(AGENTS_DIR) ] || { echo "MISSING: sibling checkout $(AGENTS_DIR)"; fail=1; }; \
	echo "host $$(uname -m)"; \
	[ $$fail -eq 0 ] && echo "preflight OK" || exit 1

##@ Build

$(BUILD_DIR):
	@mkdir -p $@

.PHONY: checkout-extensions
checkout-extensions: | $(BUILD_DIR) ## Fetch siderolabs/extensions at the pinned commit, overlay patches/extensions/.
	@if [ ! -d "$(EXTENSIONS_DIR)/.git" ]; then \
	  echo "==> cloning siderolabs/extensions"; \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/extensions.git $(EXTENSIONS_DIR); \
	fi
	@git -C $(EXTENSIONS_DIR) fetch --quiet --filter=blob:none origin $(UPSTREAM_EXTENSIONS_REF) 2>/dev/null || git -C $(EXTENSIONS_DIR) fetch --quiet origin
	@git -C $(EXTENSIONS_DIR) checkout --quiet --force --detach $(UPSTREAM_EXTENSIONS_REF)
	@rm -rf $(EXTENSIONS_DIR)/router
	@cp -r patches/extensions/router $(EXTENSIONS_DIR)/router

.PHONY: agents
agents: ## Cross-compile the router extension-service daemon (../talos-extensions).
	@test -d $(AGENTS_DIR) || { echo "sibling checkout not found: $(AGENTS_DIR)"; exit 1; }
	@command -v cargo-zigbuild >/dev/null || { echo "MISSING: cargo-zigbuild"; exit 1; }
	@rustup target add $(AGENT_RUST_TARGET) >/dev/null 2>&1 || true
	@echo "==> cross-compiling router for $(TARGET_ARCH) ($(AGENT_RUST_TARGET))"
	@(cd $(AGENTS_DIR) && cargo zigbuild --release --target $(AGENT_RUST_TARGET) -p router)

# Field order here is load-bearing, not stylistic: siderolabs' own extensions-validator
# (cmd/extensions-validator/cmd/validate.go) only accepts a handful of exact version
# shapes via regex, and the one that fits a hash + a Talos version + extra free-form
# text is `^([0-9a-f]+)-v(\d+\.\d+\.\d+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?)...$` - a
# lowercase-hex token, then literal "-v", then TALOS_VERSION's own X.Y.Z, with anything
# else (BIRD_VERSION here) only valid as a further "-"-prefixed suffix *after* that,
# folded into the semver prerelease part. AGENTS_SHA has to come first for exactly this
# reason (confirmed the hard way: BIRD_VERSION-TALOS_VERSION-AGENTS_SHA and
# bird+BIRD_VERSION-TALOS_VERSION-AGENTS_SHA both rejected with "invalid version format" -
# same regex talos-awg-extension's own EXT_VERSION already satisfies by luck of field
# order, not by design there either).
EXT_VERSION := $(AGENTS_SHA)-$(TALOS_VERSION)-bird$(BIRD_VERSION)

BIRD_ARGS := --build-arg=BIRD_VERSION=$(BIRD_VERSION) --build-arg=BIRD_SHA256=$(BIRD_SHA256) --build-arg=BIRD_SHA512=$(BIRD_SHA512)

.PHONY: extension
extension: agents checkout-extensions ## Package bird/birdc + the router daemon into a Talos system extension image (bldr).
	@cp $(AGENTS_DIR)/target/$(AGENT_RUST_TARGET)/release/router $(EXTENSIONS_DIR)/router/router-bin
	@cp $(AGENTS_DIR)/extension-services/router.yaml $(EXTENSIONS_DIR)/router/router-service.yaml
	@echo "==> building $(EXT_IMAGE) ($(TARGET_ARCH))"
	@$(MAKE) -C $(EXTENSIONS_DIR) docker-router PLATFORM=linux/$(TARGET_ARCH) \
	  TARGET_ARGS="--tag=$(EXT_IMAGE) --push=true $(BIRD_ARGS) --build-arg=VERSION=$(EXT_VERSION)"
	@echo
	@echo "published: $(EXT_IMAGE)"
	@echo "talos-installer needs this ref to bundle it into an installer"

.PHONY: all
all: preflight extension ## Everything: agents -> extension image.

##@ Maintenance

.PHONY: hashes
hashes: ## Recompute BIRD_SHA256/BIRD_SHA512 for the current BIRD_VERSION.
	@tmp=$$(mktemp); \
	curl -sSL --fail "https://gitlab.nic.cz/labs/bird/-/archive/v$(BIRD_VERSION)/bird-v$(BIRD_VERSION).tar.gz" -o "$$tmp"; \
	echo "BIRD_SHA256=$$(sha256sum "$$tmp" | cut -d' ' -f1)"; \
	echo "BIRD_SHA512=$$(sha512sum "$$tmp" | cut -d' ' -f1)"; \
	rm -f "$$tmp"

.PHONY: clean
clean: ## No separate build output to drop - kept for symmetry with the other repos.
	@true

.PHONY: distclean
distclean: ## Drop everything, including the pinned checkout.
	@rm -rf $(BUILD_DIR)
