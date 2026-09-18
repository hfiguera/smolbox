# smolvm 1.16.1 qualification

Status: **1.16.1 is the default in this checkout; unreleased. Explicit 1.16.0 support remains.**

Branch: `qualify-smolvm-1.16.1`, starting at
`9c212ef29ed446307d45de8084c4acef336b68aa`. Campaign date: September 18, 2026 UTC.

The initial candidate passed normal execution, durable recovery and network enforcement
checks on the tested platforms. Two disk-exhaustion regressions failed at stop,
and a direct comparison confirmed different behavior from 1.16.0. Public
worker/network admission was initially held, with default runtime 1.16.0.
That initial campaign changed no package version, durable schema or
lifecycle semantics. The cleanup follow-up below is a separate implementation change.

## Original blocker

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

SmolBox's original managed cleanup implementation stopped and reinspected a machine
before deleting it. A failed stop caused retry, so that implementation could not
advance to deletion in the observed state. The direct diagnostic deletion above
was an intentional discard of a completed synthetic workload, not a change to
managed cleanup and not proof that managed cleanup passed.

This is a compatibility problem between a deliberate upstream safety change and
SmolBox's original cleanup sequence. It is not evidence of a VM escape, failed
network enforcement or general unreliability of 1.16.1.

## Cleanup separation follow-up

The managed runtime now chooses preservation or disposal from persisted state,
before issuing a mutation. Finished execution/collection and expired unknown
retention select DELETE directly. Unknown work still within retention selects
graceful stop and keeps its disks. A failed stop does not switch paths. The
low-level stop API remains unchanged. Explicit public admission is enabled in
the subsequent admission decision below.

Both paths retain creation/incarnation checks, store claims, fixed deadlines and
finite attempt budgets. A DELETE acknowledgment does not complete cleanup until
inspection observes absence and that evidence is stored; reservation release
remains a separate guarded operation. No command is replayed, and discarded
unknown work retains its unknown outcome. Retry exhaustion is still conservative:
retention expiry does not reset attempts or authorize additional mutations.

The new `scripts/lab/managed-discard.exs` exercises an entire managed execution
against the real worker. A test transport observes free host backing space at
the DELETE boundary and rejects any unexpected stop request in the completed
case. It never substitutes a response for the worker. Run it only in the disposable
Linux lab. Current checkouts need no admission patch; earlier campaign checkouts
used the historical patch described below:

```sh
SMOLBOX_RUNTIME_VERSION=1.16.1 SMOLBOX_DISCARD_LABEL=discard-cache \
  mix run scripts/lab/managed-discard.exs
# With the separately prepared shared-storage worker:
SMOLBOX_RUNTIME_VERSION=1.16.1 SMOLBOX_DISCARD_LABEL=discard-shared \
  SMOLBOX_RUNTIME_SOCKET=/srv/smolbox-cleanup/run/api.sock \
  SMOLBOX_DISCARD_STORAGE=/srv/smolbox-cleanup/data \
  mix run scripts/lab/managed-discard.exs
# Reset the candidate before testing cancellation/preservation:
SMOLBOX_RUNTIME_VERSION=1.16.1 SMOLBOX_DISCARD_LABEL=preserve-cache \
  SMOLBOX_DISCARD_MODE=unknown mix run scripts/lab/managed-discard.exs
```

### Follow-up observations

The [follow-up evidence](evidence/cleanup-preservation-disposal.json) records the
changed source hashes, successful probes and the unsuccessful intermediate runs.

These runs used the changed managed cleanup implementation, with the candidate
admission patch confined to private test checkouts:

| Scenario | Observed result |
|---|---|
| Completed workload, full 768 MiB cache | DELETE at zero available backing bytes; API absence, no owned KVM descriptors and reservation released |
| Completed workload, full 512 MiB shared registry/data mount | Same disposal and accounting observations; no preliminary stop |
| Cancelled workload with unknown outcome, full shared mount | Stop failed; same VM remained running, disks and reservation retained, no DELETE or invented exit result |
| PostgreSQL store and real recovery cases | 17 store cases and all 25 recovery cases passed in the final Linux run |
| Ordinary macOS runtime cases | Nine passed with 1.16.0 and nine with 1.16.1; no exhaustion tests on macOS |
| Deterministic contract suite | 222 passed, including eight focused preservation/disposal cases; 95.88% coverage |
| Quality and package checks | Dialyzer, Credo, ex_slop, ex_dna, Credence, documentation links and current dependency package consumer passed |

Both completed storage workloads caught the guest I/O error and exited with a
recorded status before disposal. The unknown workload was cancelled after its
storage-error observation and before the command deadline. Its expected
preservation result is deliberately different: the probe passes because SmolBox
retains uncertainty and capacity, not because graceful stop succeeded. Owned
worker teardown happens afterward and is not counted as managed cleanup.

The first follow-up SQL recovery run passed 23 of 25 cases. Both failures were
old completed-outcome assertions in the stop interruption fixtures: those fixtures
now deliberately keep the command running so they exercise preservation and
must expect an unknown outcome. After correcting the assertions, an intermediate
full run reached its 20-minute runner deadline without a final test summary; it
is retained as an incomplete run, not counted as passing. The final complete rerun
passed all 25 cases in 1,313.739 seconds with a 30-minute runner budget inside a
fresh lab, retaining the separate 45-minute outer VM limit. The owned worker
was stopped afterward and no owned KVM descriptors remained. For a full recovery rerun under the constrained nested
worker, use the existing bounded runner with an explicit budget, from
`examples/durable_host` after configuring its test database and candidate worker:

```sh
elixir ../../scripts/ci.exs bounded \
  --report /home/lab/qualification/recovery.json --timeout 1800 \
  --expected-tests 25 -- mix test test/recovery_runtime_test.exs \
  --include runtime --warnings-as-errors
```

The original stop-first probes deliberately retain their assertions and failure
records. Graceful stop under these full-disk conditions is still expected to fail;
the changed contract makes that operation unnecessary for disposable finished work.
This does not establish that failed synchronization can safely preserve pending
writes, or that retained unknown VMs can always be stopped.

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
admission enabled. The initial held branch passed all 214 deterministic cases and the complete analyzer
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
preserved in `scripts/lab/fixtures/smolvm-1.16.1-candidate.patch` for reproducing
the earlier campaign at commit `189d6e6`. Its admission implementation is now
included in this checkout, so do not apply it again. It is excluded from the
package. Historical evidence retains the admission status at the time of each run.

## Corrections and limits

- A stale negative CI fixture initially rejected the candidate version. Corrected
  candidate fixtures passed; the initial held branch intentionally rejected it
  again until the cleanup follow-up and admission decision.
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

## Admission decision

The validated cleanup follow-up separates disposal from preservation. The tested
admission rules now accept exactly 1.16.1 on Linux x86_64 and macOS Apple Silicon,
including network policies. Worker health must match the explicitly configured
version; unknown versions and mismatches still prevent execution. At that initial
admission checkpoint, the default remained 1.16.0. The subsequent default change
is recorded below; the package version remains unchanged pending a separate release.

Graceful stop can still fail when storage synchronization fails. Unknown work
within retention keeps its disks and reservation; retry exhaustion can require
operator resolution. This is the documented preservation contract, not an
unconditional cleanup guarantee. The original failing stop-first probes remain
failures and are not relabeled as passing.

The [admission evidence](evidence/smolvm-1.16.1-admission.json) records 224 passing
deterministic cases, 95.88% coverage, the full analyzer pipeline, nine fresh
ordinary macOS runtime cases and successful current/minimum dependency package
consumers. All 43 library modules match the qualified candidate implementation
when documentation attributes and source locations are excluded from the AST
comparison. The Linux comparison reconstructs the exact archived inputs plus the
recorded admission patch and final cleanup source; original host copies match
the recorded hashes. The real Linux results above are reused, not claimed as a
new run. Historical evidence retains its original held-admission status.

## Default selection follow-up

On September 18, 2026, this checkout changed the default from 1.16.0 to 1.16.1.
Explicit 1.16.0, 1.14.6 and 1.14.1 support remains. The library, maintainer
preflight, runtime helpers and current host examples use the same default.
Published SmolBox 0.1.3 is unchanged and still defaults to 1.16.0.

A fresh macOS run removed `SMOLBOX_RUNTIME_VERSION` entirely: all nine ordinary
runtime cases passed, including managed execution and verified cleanup. Current
and minimum dependency consumers accepted the new default and explicit 1.16.0,
and rejected an unqualified version. Deterministic tests also rejected a 1.16.0
worker when the controller expected the new default.

Comparison of all 43 library modules against the admission checkpoint found only
the intended executable change to the `WorkerConfig` default. Linux runtime,
network enforcement, durable recovery and exhaustion evidence above is reused;
no fresh Linux run or additional isolation guarantee is claimed for this change.
See the [default validation record](evidence/smolvm-1.16.1-default.json) for check
results, source hashes and the exact package snapshots tested.

Upgrade the separately installed worker using the drain and verification steps
in [Managed host integration](host-integration.md#upgrading-a-worker), or set
`runtime_version: "1.16.0"` before upgrading the library. The package does not
upgrade workers or silently fall back. No additional record migration is needed.
