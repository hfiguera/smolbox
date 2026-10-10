# Controlled network access

Approve specific outbound destinations when a guest needs network access.
Offline remains the default. These policies require a supported smolvm version
from **1.16.0** onward; see [Supported platforms](supported-platforms.md).

Outbound policy does not enable host image downloads, inbound mappings, mounts
or credential forwarding. Configure fixed TCP [port mappings](port-mappings.md)
separately. With mappings, `:offline` denies outbound traffic while attaching a
virtio-net device for inbound forwarding.

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
- This is outbound control. Published guest ports are a separate [machine feature](port-mappings.md).
- `smolvm serve` 1.16.0 and 1.16.1 default to a strict egress floor that also denies private,
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

Network policy was introduced in record schema v2. The codec reads exact v1
records by adding only explicit offline defaults to the old profile and machine
observation shapes.
Offline execution fingerprints retain their previous representation, so resubmitting
an old execution does not acquire a new identity. Malformed v1 records and v1
records containing network fields are rejected. Do not downgrade a store writer
or run old readers after v2 records have been written; coordinate this upgrade
across controllers, including offline users. Follow [Upgrading to 0.1.3](upgrading-within-0.1.x.md#upgrading-to-0-1-3).
Custom store formats need equivalent explicit migration.

## Validation

These checks cover specific policies and environments, not every protocol, DNS
attack or platform combination. For the recorded Linux and macOS runs, their
limits and reproduction commands, see [Network access tests](network-access-validation.md).

### Extended checks

The [extended test report](network-access-validation.md#extended-checks) records
IPv4/IPv6, TCP/UDP and DNS scenarios with reachable positive controls.
