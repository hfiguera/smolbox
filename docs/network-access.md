# Controlled network access

Controlled networking is introduced in SmolBox **0.1.3** and requires smolvm
**1.16.0**. SmolBox 0.1.2 does not include it. Existing profiles and machines remain offline by default.
Networking never enables image pulls, ports, mounts, or credential forwarding.

## Approve a policy

```elixir
{:ok, network} = SmolBox.NetworkPolicy.new(
  hosts: ["api.example.com"],
  cidrs: ["203.0.113.0/24"]
)

{:ok, profile} = SmolBox.Profile.new("api-access-v1",
  network: network,
  storage_gb: 1,
  overlay_gb: 1
)
```

The addresses above are documentation examples. Replace them with destinations
approved by your application's operator and use the worker's verified allocation
floors. Register this exact profile in the worker's catalog, then use it in an
execution specification as described in [Getting started](getting-started.md).
Guest code must not choose its own policy. Give changed policies new profile IDs.

The low-level client accepts the same policy:

```elixir
{:ok, machine} = SmolBox.MachineSpec.new(
  "api-job", "/approved/python.smolmachine", network: network
)
{:ok, observation} = SmolBox.Client.create(client, machine)
```

The artifact path is on the worker. Creation checks the reported runtime version
before dispatching a network-enabled create, requests `virtio-net`, and requires
the response to echo the requested allowlists and backend. Managed admission
rejects network jobs on older runtime versions. Ordinary offline use of 1.14.1
and 1.14.6 remains supported.

Use `network: :offline` to keep networking disabled. Booleans, empty allowlists,
URLs and wildcards are rejected. A policy permits up to 32 lowercase hostnames
and 32 canonical IPv4/IPv6 CIDRs. CIDRs must have a nonzero prefix and no host
bits; lists are sorted and duplicates are rejected.
These are input constraints, not an authorization policy: a collection of broad
CIDRs can grant very broad access. Operators must review the combined destinations.

## What the policy means

- A hostname allows that name **and its subdomains**, following upstream behavior.
- Host policies learn allowed destination IPs from DNS replies. They do not
  restrict HTTP paths, TLS server names, application protocols or destination ports.
  Another service on an allowed IP may be reachable.
- CIDRs and addresses learned through approved DNS names are combined.
- An empty hostname list requests denial of ordinary guest DNS names, including for a
  CIDR-only policy. Add approved names when DNS resolution is needed.
- DNS resolution has its own upstream handling and can be permitted for an
  otherwise restricted policy. Do not treat this feature as preventing every
  DNS-based data disclosure.
- Upstream platform rules, the worker network and external firewalls can deny
  additional destinations. Declaring an allowlist does not establish connectivity.
- This is outbound control. There are no published guest ports in this feature.
- `smolvm serve` 1.16.0 defaults to a strict egress floor that also denies private,
  loopback and metadata destinations, including addresses learned from DNS. Keep
  that floor in deployments handling untrusted workloads. An operator can weaken
  it through the worker environment; SmolBox does not configure or attest it.
- The allowlist has upstream infrastructure exceptions: the guest DNS gateway,
  its built-in `host.smolvm.internal` name, and
  a dedicated rollout endpoint on gateway port `10081`. The rollout endpoint is
  reachable by network-enabled guests even when absent from their allowlist. It
  requires a lease credential and does not expose machine-management routes.
  SmolBox does not issue those credentials or use that endpoint. Do not describe
  an enabled policy as allowing *only* its listed addresses.

Applications still own access authorization, approved images, worker placement,
credentials and host network controls. Keep worker control interfaces and unrelated
services unreachable from guest workloads. See [Security](security.md).

## Durable identity and upgrades

The profile's policy participates in execution fingerprints and creation evidence.
A changed or missing policy is not accepted as the same machine incarnation.
An uncertain create is not replayed, even if policy verification fails. Recovery
keeps the existing ownership and cleanup rules.

The record codec now writes schema v2. It reads exact v1 records by adding only
explicit offline defaults to the old profile and machine observation shapes.
Offline execution fingerprints retain their previous representation, so resubmitting
an old execution does not acquire a new identity. Malformed v1 records and v1
records containing network fields are rejected. Do not downgrade a store writer
or run old readers after v2 records have been written; coordinate this upgrade
across controllers, including offline users. Follow [Upgrading to 0.1.3](recovery.md#upgrading-to-0-1-3).
Custom store formats need equivalent explicit migration.

## Validation

The controlled Linux fixture uses the disposable nested KVM lab. Allowed and
blocked TCP responders and a DNS responder live exclusively in the worker's
private network namespace. Both TCP endpoints are checked from that namespace
before guest denials are counted. The fixture checks offline behavior, CIDR
rules, hostname and subdomain rules, unrelated names, and policy retention across
stop/start. On September 14, 2026, all three policies passed with official smolvm
1.16.0 on Linux x86_64: six probes per policy, followed by allowed/denied checks
after restart, deletion and absence of owned KVM descriptors. Managed execution
also completed an allowed request, retained its policy through record encoding,
recognized a duplicate submission and finished cleanup with an empty worker.

### Extended checks

The follow-up campaign tested five Linux configurations: offline, IPv4 CIDR,
IPv6 CIDR, hostname with the server default, and hostname with an explicit
`SMOLVM_EGRESS_FLOOR=strict`. Each configuration used reachable synthetic endpoints
and checked:

- Allowed and denied TCP connections and UDP request/reply traffic over IPv4
  and IPv6, plus IPv4-mapped IPv6 addresses. An IPv4-only policy did not open
  IPv6 access; the converse also held.
- DNS over UDP and TCP, denied names, a misleading suffix, an alternate resolver,
  and IP learning from both A and AAAA replies.
- An approved DNS name changing from an allowed address to a synthetic private
  control address, plus names resolving to loopback and metadata addresses.
- Access to a synthetic control service and the gateway. The separate rollout
  endpoint rejected missing and invalid credentials with HTTP 401; a request for
  its machine-management route returned 404.
- Address policy behavior after restart, deletion, and absence of owned KVM
  descriptors after worker shutdown.

The responders include both permitted and denied destinations. Positive controls
establish that the worker can reach them before guest denials count. IPv6 is
entirely local to the namespace: a synthetic responder satisfies upstream's
IPv6 connectivity probe without opening an Internet route. DNS rebinding results
apply to the tested private, loopback and metadata targets under the strict floor;
they do not establish that every possible DNS attack is prevented.

Bounded macOS Apple Silicon checks also exercised offline, IPv4 CIDR and hostname
policies using ordinary TCP connections to public services. All three passed
before and after restart, with each machine deleted. These checks used the
verified official 1.16.0 distribution and an approved Python artifact. They did
not run hostile payloads or exhaustion tests on the Mac.

Linux evidence now includes IPv6 and UDP enforcement; macOS evidence covers
IPv4 TCP and DNS compatibility; this Mac had no IPv6 route, so no live macOS
IPv6 result is claimed. The campaign does not qualify every protocol,
packet mutation, DNS attack, macOS IPv6/UDP combination, external API, browser
automation workload or tenant configuration. The resource/exhaustion campaign
remains a separate qualification. No adversarial networking ran on the physical
Linux host or developer's Mac.

The repository's `docs/evidence/controlled-network-access.json` preserves the
initial campaign. `docs/evidence/controlled-network-extended.json` records the
follow-up reports, runtime/artifact pins, source hashes and final cleanup.
Reproduce the isolated Linux checks with `scripts/lab/network-extended.sh`,
setting a unique `SMOLBOX_NETWORK_ATTEMPT`, only inside the prepared disposable
lab. The original `scripts/lab/network-access.sh` retains its managed execution
case via `SMOLBOX_NETWORK_MANAGED=true`. The bounded Mac script is
`scripts/lab/network-macos.exs`; it requires a dedicated empty worker at
`$SMOLBOX_NETWORK_MAC_ROOT/api.sock` and an approved `$SMOLBOX_PYTHON_ARTIFACT`.
These fixtures are not a general network security certification.
