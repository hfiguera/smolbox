# smolvm 1.16.1 qualification

Status: **qualification blocked; 1.16.1 remains unsupported**.

Branch: `qualify-smolvm-1.16.1`, starting at
`9c212ef29ed446307d45de8084c4acef336b68aa`. Campaign date: September 18, 2026 UTC.

The candidate passed normal execution, durable recovery and network enforcement
checks on the tested platforms. Two disk-exhaustion regressions failed at stop,
and a direct comparison confirmed different behavior from 1.16.0. Public
worker/network admission therefore remains unchanged, with default runtime
1.16.0. No package version, durable schema or lifecycle semantics changed.

## The blocker

Version 1.16.1 requires the guest to acknowledge filesystem synchronization before
graceful shutdown. When the constrained worker's cache filled, the guest returned
an I/O error while freezing `/storage`. Upstream deliberately preserved the live
VM instead of treating that failed synchronization as a successful stop.

The original resource probe failed cleanup with a SmolBox protocol error and
`evidence: :dispatch_uncertain`. The separate shared-registry/storage regression
also failed at `Client.stop/2`, before reaching deletion. External lab teardown
removed the owned processes; that does not count as successful API cleanup.

A second comparison used the same prepared artifact, worker configuration and
768 MiB cache filesystem, changing only the complete runtime distribution:

| Observation | 1.16.0 | 1.16.1 |
|---|---|---|
| Bytes written before the guest's I/O error | 586,153,984 | 586,153,984 |
| Stop HTTP status | 200 | 500 |
| Observed machine state afterward | stopped | running |
| Explicit diagnostic deletion afterward | verified absent | verified absent |

SmolBox's existing managed cleanup implementation stops and reinspects a machine
before deleting it. A failed stop causes retry, so that implementation cannot
advance to deletion in the observed state. The direct diagnostic deletion above
was an intentional discard of a completed synthetic workload, not a change to
managed cleanup and not proof that managed cleanup passed.

This is a compatibility problem between a deliberate upstream safety change and
SmolBox's current cleanup sequence. It is not evidence of a VM escape, failed
network enforcement or general unreliability of 1.16.1.

## Inputs and review

The external reference checkout was inspected without modification at
`adec01f0df99aaf820aa09d4e6e665a31ac3ec07`. Tests used official tag `v1.16.1`,
commit `9504e94e3581a1f52c414247edcbcd6d6b49a71a`, excluding later main changes.

| Platform archive | SHA-256 |
|---|---|
| Linux x86_64 | `e49e5bbae6d65b039ecf1d8b236d20e77427b7bfd131907b27a0819fcdea3fed` |
| Darwin ARM64 | `44b50573962b34ee979bb74a5756bd10583e20fd1d3739baa28147d13b5a26f3` |
| Linux 1.16.0 comparison | `cb7d6ea34914b4d71958e16eafc8a3220fe9e8cd5b76fa983ef9f648159f4c9b` |

Downloads matched official release asset digests; the 1.16.1 archives also matched
published `checksums.sha256`. Complete installations included the matching agent
and hypervisor libraries and passed their bundled component checksum checks.

The exported schema retains all eight paths used by SmolBox. Among nineteen
referenced schemas, `MachineInfo` adds an optional `image` field. Captured responses
exercise that additive field without weakening identity or allocation checks.
The tagged exec/file handlers are unchanged from 1.16.0. The graceful shutdown
change was introduced by upstream commit `3c5c37014dc666972e6b6a16d72f2ee69ead4a32`.

## Completed tests

| Check | Linux x86_64 | macOS ARM64 |
|---|---|---|
| Real runtime cases | 14 passed | 9 ordinary cases passed |
| PostgreSQL store cases | 17 passed | 17 passed |
| Durable recovery cases | 25 passed | 25 passed |
| API restart, unavailability and missing-machine scenarios | 3 passed | 3 passed |
| Policy and restart checks | offline, IPv4/IPv6 CIDR, hostname and strict floor passed | offline, IPv4 CIDR and hostname passed |
| Geometry and stop/start file persistence | passed | Python and Node passed |
| Resource/containment probes | 10 passed; disk cleanup failed | not run |
| Shared-storage cleanup regression | failed at stop | not run |

The Linux durable suite took 1,160.796 seconds under the constrained nested
configuration. Completed execution/recovery checks cover binary files, Python
and JavaScript, nonzero exits, streamed output, cancellation, uncertain outcomes,
identity preservation and cleanup. API outage checks observed one command
dispatch rather than replaying the execution after a lost response.

Linux reused the approved baseline Python and Node artifacts. macOS prepared
fresh artifacts with the official distribution, private HOME and empty credential
configuration. Earlier temporary macOS artifacts were unavailable. Actual 1 GiB
storage and overlay disks retained files across stop/start when host `resize2fs`
was available: e2fsprogs 1.47.0 on Linux and Homebrew 1.47.4 on macOS.

Extended Linux networking used reachable synthetic positive controls for TCP/UDP
over IPv4/IPv6, DNS, restart and private/control endpoint denial. The documented
DNS gateway and credentialed rollout endpoint exceptions remain: missing/invalid
rollout credentials returned 401; a management route returned 404. These results
do not establish that an allowlist excludes every infrastructure endpoint.

The candidate passed 215 deterministic cases, all configured analyzers and 95.49%
coverage. Eight analyzer/coverage canary pairs exercised both detection and clean
controls. Current and minimum dependency package consumers passed with candidate
admission enabled. The final branch passed all 214 deterministic cases and the complete analyzer
pipeline with 1.16.1 rejected after removing candidate admission.

## Reproducing the evidence

The [evidence JSON](evidence/smolvm-1.16.1.json) records distribution/artifact hashes,
runner results, failures, comparison responses and limitations. Raw logs and both
lab-cycle archives are retained in the maintainer's private qualification directory.

Use only the disposable nested Linux lab for the storage probes. Install and
verify each complete runtime first, then select it with
`scripts/lab/select-runtime.sh`. Start a clean candidate with
`scripts/lab/candidate-control.sh` before each probe. The comparison is:

```sh
SMOLBOX_RUNTIME_VERSION=1.16.0 mix run scripts/lab/disk-stop-compatibility.exs
# Stop/reset the candidate, select 1.16.1, and start a clean worker before:
SMOLBOX_RUNTIME_VERSION=1.16.1 mix run scripts/lab/disk-stop-compatibility.exs
```

The comparison asserts the observed difference; its successful exit means the
incompatibility was reproduced, not that 1.16.1 passed qualification. Existing
`qualification-probe.exs disk` and `cleanup-regression.exs` retain their original
successful-cleanup assertions and fail against this candidate.

The temporary public-admission changes used by managed candidate tests are
preserved in `scripts/lab/fixtures/smolvm-1.16.1-candidate.patch`. Apply that patch
only to a separate qualification checkout to reproduce those tests. It is not
applied on this branch, not included in the package, and not an operator opt-in.
Pinned maintainer preflight recognizes the candidate distribution without
claiming that the public library supports it.

## Corrections and limits

- A stale negative CI fixture initially rejected the candidate version. Corrected
  candidate fixtures passed; the final branch intentionally rejects it again.
- The first macOS geometry probe inspected a Linux-style cache path. The corrected
  native path produced real size/persistence evidence; the initial failure remains.
- The first Linux store report expected 16 cases although all 17 passed. Correcting
  the report count and rerunning produced 17 passing cases again. Its relative
  teardown path was also corrected to an absolute path.
- Separate lab cycles preserved the existing 45-minute outer VM deadline. Owned
  worker teardown and KVM descriptor checks remained independent of API cleanup.
- No macOS exhaustion/adversarial testing, macOS IPv6 qualification, Linux ARM64
  support or new hard resource guarantee is claimed.
- Checkpoint, branching, GPU, SDK and Nix behavior were outside this contract.
- Short command/observation deadlines were tested. The separate HTTP operations
  exceeding five minutes from 1.16.0 were not repeated; source review alone does
  not replace those measurements.
- Missing-`resize2fs` behavior and every older macOS artifact were not retested.

## What would unblock admission

Resolve the stop/delete incompatibility without silently discarding uncertain
work or claiming termination before observing it. That requires either a
solution compatible with upstream or a separately reviewed change to SmolBox's cleanup
contract; this task does neither. Then repeat the original disk and shared-storage
regressions, managed recovery and platform checks before enabling admission.
The passing network and normal execution results remain useful evidence, but
cannot substitute for that missing cleanup result.
