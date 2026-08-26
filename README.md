# talos-router-extension

Packages the **router** Talos system extension - a daemon (`talos-extensions/router`)
that renders BIRD config (OSPFv3 over mesh links, full-mesh iBGP over loopbacks) and
resolves bypass-route prefixes from a static config file, supervising a bundled `bird`
(talking to it over BIRD's own control socket directly - no `birdc` CLI binary needed).
No kernel module involved - pure userspace, fully independent of `talos-kernel`.

Builds with **Docker** (`docker buildx`), on any machine, for any target architecture.

## This is one of five repos

- [talos-kernel](https://github.com/slipmesh/talos-kernel) —
  signed kernel + `amneziawg-pkg`
- [talos-awg-extension](https://github.com/slipmesh/talos-awg-extension) —
  amneziawg system extension (pulls `amneziawg-pkg`)
- [talos-router-extension](https://github.com/slipmesh/talos-router-extension) —
  router system extension (no kernel dependency) — **this repo**
- [talos-nftables-extension](https://github.com/slipmesh/talos-nftables-extension) —
  nftables system extension (no kernel dependency)
- [talos-installer](https://github.com/slipmesh/talos-installer) —
  assembles a kernel + N extensions into an installer

Each repo builds and publishes independently. Unlike `talos-awg-extension`, this repo
doesn't need `talos-kernel` built first - `preflight` has no dependency-image check.

### One checkout it does need

`make agents` cross-compiles the daemon out of
[talos-extensions](https://github.com/slipmesh/talos-extensions), so that repository has to exist
on disk - it's the one thing here that isn't consumed as a published image. The default is a
sibling checkout, `AGENTS_DIR := ../talos-extensions`; clone the two side by side, or point it
anywhere:

```sh
make extension TARGET_ARCH=amd64 RELEASE_TAG=... AGENTS_DIR=/path/to/talos-extensions
```

`preflight` fails loudly if the directory isn't there.

## How it works

Same mechanism `talos-awg-extension` uses for packaging (siderolabs/extensions'
`pkg.yaml`/`bldr` pipeline), and the same way it gets its payload: BIRD is not built here
but pulled in as a published image, `ghcr.io/slipmesh/bird`, which
[bird](https://github.com/slipmesh/bird) builds statically from upstream. A dependency
image is an OCI layer merge rather than a second build, so there is one BIRD to keep
current instead of two, and this repository has no source download of its own to pin.

The `router` daemon never invokes `birdc` - it implements BIRD's control-socket protocol
directly (see `talos-extensions`' `router/src/birdc.rs`) - but the binary ships anyway,
because it is what a human needs when debugging a node.

```text
versions.env            every pin: Talos version, extensions commit, BIRD version, image
patches/extensions/router/  overlaid onto a siderolabs/extensions checkout - builds BIRD,
                             packages it + the router daemon into an extension
build/                   (gitignored) the extensions checkout
```

`build/` is disposable: `make distclean && make extension TARGET_ARCH=<arch>` reproduces
it from `versions.env` and `patches/` alone.

The `router` binary itself lives in the sibling repo `talos-extensions` and is
cross-compiled by `make agents`, then handed to the `siderolabs/extensions` checkout for
packaging alongside `bird` (part of `make extension`).

## Cross-architecture

```sh
make extension TARGET_ARCH=amd64 RELEASE_TAG=v0.1.0+bird2.18
make extension TARGET_ARCH=arm64 RELEASE_TAG=v0.1.0+bird2.18
```

## Usage

Every build/publish target needs `TARGET_ARCH=amd64|arm64` and `RELEASE_TAG=<the git tag
being released>` (no defaults). Like `bird`, `RELEASE_TAG` *is* the published image tag
(`+` swapped for `-`, since OCI tags can't contain `+`) - see `cliff.toml`'s `tag_pattern`
for the exact shape (`vX.Y.Z[+birdA.B.C]`).

```sh
make print-config   # resolved pins, arch, image names
make preflight       # docker/buildx/git/curl/cargo/cargo-zigbuild present
make agents            # cross-compile router from ../talos-extensions
make extension           # build bird + package with the router daemon (this arch)
make all                   # preflight -> extension
```

`make extension` pushes straight to `ghcr.io/slipmesh/talos-router-extension` and prints the tag -
`talos-installer` needs that ref to bundle it into an installer.

## Verifying a build

`patches/extensions/router/pkg.yaml`'s own `test:` step runs siderolabs' own
`extensions-validator` against the assembled manifest/rootfs - a build that completes has
already proven the extension is structurally valid.

```sh
docker buildx imagetools inspect <image>   # arch, manifest
```

Full node-level verification (bird/router running, OSPF/BGP sessions up) happens after
`talos-installer` bundles this extension and a node runs `talosctl upgrade` - see that
repo's README, and `talos-extensions/router`'s own docs for the daemon's own config
schema and machine-config example.

## Bumping

**BIRD:** release it in [bird](https://github.com/slipmesh/bird) first, then set
`BIRD_IMAGE_TAG` to the image that release published and `BIRD_VERSION` to the BIRD inside
it - the second names this extension's own version and release tag, and nothing checks that
the two agree. Then `make extension TARGET_ARCH=<arch> RELEASE_TAG=<new release tag>`.

**siderolabs/extensions:** bump `UPSTREAM_EXTENSIONS_REF` freely; it only needs to
resolve.

**router daemon:** any commit in `talos-extensions` - `make extension` always picks up
whatever's currently checked out there and tags accordingly (see `AGENTS_SHA` in the
`Makefile`), no version bump needed here.
