# The `ext-router` extension service

This extension carries three files, all under `rootfs/usr/local/lib/containers/router/`:

1. `router` - the extension-service daemon itself (a Rust binary, cross-compiled from the
   sibling repo `../talos-extensions`).
2. `bird`/`birdc` - a prebuilt, fully static BIRD build, extracted verbatim from
   `ghcr.io/slipmesh/bird` (`../bird`) - `router` spawns `bird` itself as a child process and
   talks to its control socket directly (not through the `birdc` binary, which is bundled only
   for manual `talosctl exec`-style debugging).

`router` renders BIRD's config (OSPFv3 over mesh links, full-mesh iBGP over loopbacks,
bypass-route blackholing) and reloads it live over BIRD's control socket - a separate mechanism
from the kernel module `ext-awg` deals with. Without it, `bird` never starts and no routing
happens at all.

## Why this exists

Talos nodes need mesh route exchange (which node reaches which pod/service/bypass range,
learned over OSPF/iBGP) the same way they need AmneziaWG interfaces up before/without a
Kubernetes API - `slipmesh-operators`' `router` (see github.com/slipmesh/operators) solves the
equivalent problem for already-clustered nodes, driven by Kubernetes CRDs; `ext-router` solves
it for a node that hasn't joined a cluster yet (or never will), driven by a static config file
instead. See `../talos-extensions/README.md`'s `## router` section for the full design
rationale (what got ported from the k8s original, what got dropped, and why) and
`../talos-extensions/AGENTS.md` for the invariants a future change here must not break (no
Kubernetes dependency, no CRD-derived topology, etc).

## Config: everything declared statically, nothing discovered

Unlike the k8s original, there's no `MeshLink`/`NodeConfig` CRD to read a node's peers or
mesh-interface names from - `router.yaml` declares all of it directly:

```yaml
node:
  loopback_addresses:               # CIDR strings, with or without an explicit prefix length
    - 10.62.0.1/32                  # IPv4 loopback - BIRD router id, krt_prefsrc, OSPFv3 stub network
    - fd00::1/128                   # IPv6 loopback - this node's iBGP session source address
bgp_as: 64512
bgp_peers:                          # one entry per other mesh node - can't be auto-discovered
  - name: fra
    address: fd00::2                # a single bare IPv6 address (no prefix - this isn't a network)
  - name: lon
    address: fd00::3
ospf_interfaces:                    # exact names, shell-glob patterns ("mesh-*"), or CIDRs by address -
  - "mesh-*"                        # fed straight into BIRD's own `interface` clause, matching
                                     # ext-awg's mesh-<short_id> interface naming
learn:                              # IPv4 CIDR *ranges* (not exact per-peer /32s) re-announced over
  - "10.99.0.0/24"                  # iBGP whenever a kernel-learned route falls inside one
announce:                           # static routes redistributed into iBGP
  - net: "10.96.0.0/12"
    label: "k8s-services"
bypass:                             # optional - resolved live (RIPEstat/DNS), the one part of this
  refresh_interval_secs: 86400      # config that stays "live" instead of fully static
  include:
    - kind: asn                     # "asn" | "literal" | "geoip" | "dns"
      label: "some vendor"
      asns: ["AS15169"]
  exclude:
    - kind: literal
      prefixes: [{net: "10.0.0.0/8"}]
```

`node.loopback_addresses` must contain exactly one IPv4 and exactly one IPv6 entry - both are
used simultaneously for different roles, not "any one of these" (`../talos-extensions/router/
src/config.rs`'s `validate` enforces this). `bgp_peers[].address` is a single bare IPv6 address,
not a list: a BIRD `protocol bgp` instance takes exactly one `local`/`neighbor` address each, so
a list there would imply failover support BIRD's config syntax doesn't have.

**No cluster-wide self/peer-endpoint exclusion is automatic.** The k8s original always punched
every cluster node's own endpoint out of `bypass` (sourced from every `NodeConfig`); a static,
per-node config has no such list to read. Whoever authors `router.yaml`'s `bypass.exclude` is
responsible for excluding this node's own (and any peer's) public endpoint themselves if it
could otherwise fall inside `bypass.include` - the same config-authoring-is-a-human-
responsibility pattern `../talos-awg-extension/docs/extension-services.md` documents for
`ext-awg`'s private keys.

## Full machine config example

Multi-document machine config YAML - the `ExtensionServiceConfig` document's `name` must match
the service name (`router`), and its `configFiles[].mountPath` must be exactly
`/etc/talos-extensions/router.yaml` (the fixed path `ext-router` reads - not configurable, same
"no env vars, no CLI flags" invariant `ext-awg` follows):

```yaml
# ... the rest of a normal v1alpha1 machine config, including whatever ExtensionServiceConfig
# ext-awg needs (see ../talos-awg-extension/docs/extension-services.md) ...
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: router
configFiles:
  - mountPath: /etc/talos-extensions/router.yaml
    content: |
      node:
        loopback_addresses: ["10.62.0.1/32", "fd00::1/128"]
      bgp_as: 64512
      bgp_peers:
        - name: fra
          address: fd00::2
      ospf_interfaces: ["mesh-*"]
```

Applying this document (`talosctl apply-config`) restarts `ext-router`'s whole container - both
`router` and the `bird` child process it spawns, fresh - the same `handleRestart()` behavior
`../talos-awg-extension/docs/extension-services.md` documents for `ext-awg` (confirmed against
Talos source there; applies identically to every extension service, not something specific to
`ext-awg`).

## Verifying a build

Same spirit as `../talos-awg-extension`'s "Verifying a build" - check the artifact, don't trust
a clean exit code:

```sh
file build/out-<arch>/rootfs/usr/local/lib/containers/router/router   # ELF ... statically linked, stripped
file build/out-<arch>/rootfs/usr/local/lib/containers/router/bird     # ELF ... statically linked, stripped
build/out-<arch>/rootfs/usr/local/lib/containers/router/router --help 2>&1 || true   # confirm it's the real binary, not a stub
```

## Verifying on a real node

- `talosctl -n <node> get extensions` - a `router` extension entry.
- `talosctl -n <node> service ext-router` - state (should be `Running` once converged; `restart:
  always`, so any startup failure - including `bird` itself exiting - retries every 5s rather
  than sitting in `Failed`).
- `talosctl -n <node> logs ext-router` and `talosctl -n <node> dmesg | grep -i bird` (the
  service runs with `logToConsole: true`; `bird`'s own `log stderr {...}` output is inherited by
  `router`'s stdio, so both daemons' logs land in the same place).
- Edit the `ExtensionServiceConfig` document (add/remove a `bgp_peers` entry or an
  `ospf_interfaces` pattern), `talosctl apply-config`, confirm the change is live within seconds
  without a reboot.

## Local smoke test (before touching a real node)

Needs a Linux host/VM/container with `CAP_NET_ADMIN` (for the `router-lo` dummy interface) and
both binaries built:

```sh
cd ../talos-extensions
cargo build -p router
# bird/birdc: either `make bird TARGET_ARCH=<host-arch>` here first and copy them out, or a
# locally-installed `bird`/`birdc` (e.g. Alpine's bird2 package) - router only needs something
# that speaks BIRD's own control-socket protocol at the path it launches bird with.
sudo mkdir -p /etc/talos-extensions
sudo cp <a hand-written router.yaml> /etc/talos-extensions/router.yaml
sudo ./target/debug/router
# in another shell:
ip -d link show router-lo             # confirms the dummy loopback interface, addresses attached
sudo birdc -s /run/bird.ctl show protocols
sudo birdc -s /run/bird.ctl show ospf interface mesh6
```

Re-running after editing the config file (Ctrl-C, edit, re-run) exercises the same
render-then-reload path a real config-triggered restart would.
