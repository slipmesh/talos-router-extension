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

`make daemons` cross-compiles the daemon out of
[talos-extensions](https://github.com/slipmesh/talos-extensions), so that repository has to exist
on disk - it's the one thing here that isn't consumed as a published image. The default is a
sibling checkout, `DAEMONS_DIR := ../talos-extensions`; clone the two side by side, or point it
anywhere:

```sh
make extension TARGET_ARCH=amd64 RELEASE_TAG=... DAEMONS_DIR=/path/to/talos-extensions
```

`preflight` fails loudly if the directory isn't there.

## How it works

Same mechanism `talos-awg-extension` uses for packaging (siderolabs/extensions'
`pkg.yaml`/`bldr` pipeline). BIRD and `bird_exporter` are built here, from unmodified
upstream tags (`BIRD_REV`, `BIRD_EXPORTER_REV`), each in a bldr stage of its own:

- `router-bird` builds a fully static `bird` against glibc on Ubuntu, not on the Talos
  toolchain: that toolchain is musl, and BIRD 3 does not survive a static musl build -
  upstream's own `make check` dies in `filter_test` with SIGILL on both architectures, while
  the same tree passes against glibc. The stage runs that suite, refuses a binary with any
  `DT_NEEDED` entry (a `scratch` rootfs has nothing to load), and checks `bird --version`
  against `BIRD_REV`.
- `router-bird-exporter` builds `bird_exporter` with `CGO_ENABLED=0` and upstream's release
  flags, with the same static-link and version checks.

No BIRD client ships. `router` and `bird_exporter` both speak BIRD's control-socket protocol
themselves (see `talos-extensions`' `router/src/birdc.rs`), and the socket is only reachable
from a privileged debug pod, which can bring any client of its own: the protocol is stable
across BIRD versions. The client would also be the one thing linking GNU readline and ncurses.

```text
versions.env            every pin: Talos version, extensions commit, BIRD and exporter tags
patches/extensions/      overlaid onto a siderolabs/extensions checkout:
  router-bird/            builds BIRD
  router-bird-exporter/   builds bird_exporter
  router/                 packages both + the router daemon into the extension
build/                   (gitignored) the extensions checkout
```

`build/` is disposable: `make distclean && make extension TARGET_ARCH=<arch>` reproduces
it from `versions.env` and `patches/` alone.

The `router` binary itself lives in the sibling repo `talos-extensions` and is
cross-compiled by `make daemons`, then handed to the `siderolabs/extensions` checkout for
packaging alongside `bird` (part of `make extension`).

## Cross-architecture

```sh
make extension TARGET_ARCH=amd64 RELEASE_TAG=v0.1.0+bird2.18
make extension TARGET_ARCH=arm64 RELEASE_TAG=v0.1.0+bird2.18
```

## Usage

Every build/publish target needs `TARGET_ARCH=amd64|arm64` and `RELEASE_TAG=<the git tag
being released>` (no defaults). `RELEASE_TAG` *is* the published image tag
(`+` swapped for `-`, since OCI tags can't contain `+`) - see `cliff.toml`'s `tag_pattern`
for the exact shape (`vX.Y.Z[+birdA.B.C]`).

```sh
make print-config   # resolved pins, arch, image names
make preflight       # docker/buildx/git/curl/cargo/cargo-zigbuild present
make daemons            # cross-compile router from ../talos-extensions
make extension           # build bird + bird_exporter, package with the router daemon (this arch)
make all                   # preflight -> extension
```

`make extension` pushes straight to `ghcr.io/slipmesh/talos-router-extension` and prints the tag -
`talos-installer` needs that ref to bundle it into an installer. `PUSH=false` builds and tests
without publishing; CI does that for every pull request, and publishes only for a tag.

## Verifying a build

Every stage's `test:` step has to pass for the build to complete: BIRD's own test suite and the
static-link and version checks in `router-bird`/`router-bird-exporter`, and siderolabs'
`extensions-validator` against the assembled manifest/rootfs in `router` - a build that
completes has already proven the extension is structurally valid.

```sh
docker buildx imagetools inspect <image>   # arch, manifest
```

Full node-level verification (bird/router running, OSPF/BGP sessions up) happens after
`talos-installer` bundles this extension and a node runs `talosctl upgrade` - see that
repo's README, and `talos-extensions/router`'s own docs for the daemon's own config
schema and machine-config example.

## Bumping

**BIRD, bird_exporter:** set `BIRD_REV` or `BIRD_EXPORTER_REV` to the new upstream tag. The
BIRD version in `EXT_VERSION` is derived from `BIRD_REV`.

**siderolabs/extensions:** bump `UPSTREAM_EXTENSIONS_REF` freely; it only needs to
resolve.

**router daemon:** the `talos-extensions` release tag named by `DAEMONS_REF` -
`make check-daemons` refuses to build unless the sibling checkout sits at it, and
`DAEMONS_SHA` records the commit into `EXT_VERSION`. To pick up new daemon work, tag
`talos-extensions` and bump `DAEMONS_REF`.

## Licenses

The extension distributes BIRD (GPL-2.0-or-later), statically linked glibc (LGPL-2.1-or-later),
`bird_exporter` (MIT) and the Go modules compiled into it, so their license texts ship with it,
under `/usr/local/share/licenses/router/`. Each comes from the build itself: GPL-2 and LGPL-2.1
from the Ubuntu build image's `/usr/share/common-licenses/` - BIRD's own tree states its license
in `README` but carries no copy of the text - glibc's notice from the `libc6-dev` package, and
the Go texts from the Go toolchain and the module cache. A module without a license file fails
the build.

BIRD is built from its upstream tag without modification, so there are no changed files to
mark. The corresponding source is that tag, `BIRD_REV`, at `https://github.com/CZ-NIC/bird`;
`bird.SOURCE` beside the license texts says the same inside the image. This repository's own
code is MIT or Apache-2.0; `router` runs `bird` as a separate process and talks to it over a
socket, so it is not linked with it.
