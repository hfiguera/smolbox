# Controlled network access tests

This report preserves the environments, results and limits of the original checks.
For configuration and API usage, see [Controlled network access](network-access.md).
An older result does not establish a new test of the current release.

## Recorded checks

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

The repository's [initial network evidence](evidence/controlled-network-access.json) preserves the
initial campaign. [extended network evidence](evidence/controlled-network-extended.json) records the
follow-up reports, runtime/artifact pins, source hashes and final cleanup.
Reproduce the isolated Linux checks with `scripts/lab/network-extended.sh`,
setting a unique `SMOLBOX_NETWORK_ATTEMPT`, only inside the prepared disposable
lab. The original `scripts/lab/network-access.sh` retains its managed execution
case via `SMOLBOX_NETWORK_MANAGED=true`. The bounded Mac script is
`scripts/lab/network-macos.exs`; it requires a dedicated empty worker at
`$SMOLBOX_NETWORK_MAC_ROOT/api.sock` and an approved `$SMOLBOX_PYTHON_ARTIFACT`.
These fixtures are not a general network security certification.
