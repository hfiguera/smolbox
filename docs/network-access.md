# Controlled network access

This unreleased feature requires smolvm **1.16.0**. Published SmolBox 0.1.2 does
not include it. Existing profiles and machines remain offline by default.
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
- An empty hostname list requests denial of guest DNS names, including for a
  CIDR-only policy. Add approved names when DNS resolution is needed.
- DNS resolution has its own upstream handling and can be permitted for an
  otherwise restricted policy. Do not treat this feature as preventing every
  DNS-based data disclosure.
- Upstream platform rules, the worker network and external firewalls can deny
  additional destinations. Declaring an allowlist does not establish connectivity.
- This is outbound control. There are no published guest ports in this feature.

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
across controllers. Custom store formats need equivalent explicit migration.

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

This evidence covers **IPv4 TCP and DNS in the controlled Linux fixture**.
It does not qualify macOS networking, IPv6 enforcement, arbitrary UDP protocols,
DNS rebinding resistance, external API availability, browser automation, or a
general hostile-network threat model. IPv6 CIDRs have syntax/serialization tests
only. No adversarial networking ran on the developer's Mac or the physical Linux
host. The fixture has no route to unrelated services or the public Internet.

The repository's `docs/evidence/controlled-network-access.json` records the
runtime and artifact pins, successful reports, initial failed test assumptions,
and source hashes. Reproduce with `scripts/lab/network-access.sh` only inside the
prepared disposable lab; set `SMOLBOX_NETWORK_MANAGED=true` for the managed case
and a unique `SMOLBOX_NETWORK_ATTEMPT` for each run. This fixture is not a general
network security certification.
