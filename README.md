# talos-router-extension

Packages the **router** Talos system extension - a daemon (`../talos-extensions/router`)
that renders BIRD config (OSPFv3 over mesh links, full-mesh iBGP over loopbacks) and
resolves bypass-route prefixes from a static config file, supervising a bundled
`bird`/`birdc`. No kernel module involved - pure userspace, fully independent of
`../talos-kernel`.

Builds with **Docker** (`docker buildx`), on any machine, for any target architecture.

## This is one of four repos

```
talos-kernel                            -> signed kernel + amneziawg-pkg
talos-awg-extension                     -> amneziawg system extension (pulls amneziawg-pkg)
talos-router-extension     (this repo)  -> router system extension (no kernel dependency)
talos-installer                         -> assembles kernel + N extensions into an installer
```

Each repo builds and publishes independently. Unlike `talos-awg-extension`, this repo
doesn't need `talos-kernel` built first - `preflight` has no dependency-image check.

## How it works

Same mechanism `talos-awg-extension` uses for packaging (siderolabs/extensions'
`pkg.yaml`/`bldr` pipeline), just without a kernel-module dependency step. BIRD is built
from source as part of `patches/extensions/router/pkg.yaml` - not reused from
siderolabs/extensions' own `network/bird2` package, because that package configures
`--disable-client` (no `birdc`) and the `router` daemon needs both `bird` and `birdc` -
see the comment at the top of that file for the exact reasoning and pin provenance.

```
versions.env            every pin: Talos version, extensions commit, BIRD version, image
patches/extensions/router/  overlaid onto a siderolabs/extensions checkout - builds BIRD,
                             packages it + the router daemon into an extension
build/                   (gitignored) the extensions checkout
```

`build/` is disposable: `make distclean && make extension TARGET_ARCH=<arch>` reproduces
it from `versions.env` and `patches/` alone.

The `router` binary itself lives in the sibling repo `../talos-extensions` and is
cross-compiled by `make agents`, then handed to the `siderolabs/extensions` checkout for
packaging alongside `bird`/`birdc` (part of `make extension`).

## Cross-architecture

```sh
make extension TARGET_ARCH=amd64
make extension TARGET_ARCH=arm64
```

## Usage

```sh
make print-config   # resolved pins, arch, image names
make preflight       # docker/buildx/git/curl/cargo/cargo-zigbuild present
make agents            # cross-compile router from ../talos-extensions
make extension           # build bird/birdc + package with the router daemon (this arch)
make all                   # preflight -> extension
```

`make extension` pushes straight to `docker.io/ffaxl/talos` and prints the tag -
`../talos-installer` needs that ref to bundle it into an installer.

## Verifying a build

`patches/extensions/router/pkg.yaml`'s own `test:` step runs siderolabs' own
`extensions-validator` against the assembled manifest/rootfs - a build that completes has
already proven the extension is structurally valid.

```sh
docker buildx imagetools inspect <image>   # arch, manifest
```

Full node-level verification (bird/router running, OSPF/BGP sessions up) happens after
`../talos-installer` bundles this extension and a node runs `talosctl upgrade` - see that
repo's README, and `../talos-extensions/router`'s own docs for the daemon's own config
schema and machine-config example.

## Bumping

**BIRD:** set `BIRD_VERSION`, run `make hashes`, paste both values back, `make extension
TARGET_ARCH=<arch>`.

**siderolabs/extensions:** bump `UPSTREAM_EXTENSIONS_REF` freely; it only needs to
resolve.

**router daemon:** any commit in `../talos-extensions` - `make extension` always picks up
whatever's currently checked out there and tags accordingly (see `AGENTS_SHA` in the
`Makefile`), no version bump needed here.
