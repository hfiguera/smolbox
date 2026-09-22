# Long-running execution validation

Development-host validation on September 22, 2026, for
`feature/long-running-background-exec`, based on `dc4a4ead22998d61b266f507ade79400d42b0495`.
The [machine-readable evidence](evidence/long-running-exec.json) records source
hashes, runtime/artifact identities, measured durations, HTTP acceptance and cleanup.
This remains development qualification, not production-isolation certification.

## Real execution beyond five minutes

Official smolvm **1.17.0** distributions ran on native macOS Apple Silicon and
Linux x86_64 inside the existing disposable nested-KVM lab accessed through
`ssh linux`. Both used Elixir 1.20.4 / OTP 29.0.6. Durable examples used a private
PostgreSQL 17 cluster on macOS and PostgreSQL 16 inside the Linux lab.

| Quiet command | macOS observed duration | Linux observed duration | Verified result |
|---|---:|---:|---|
| Buffered foreground | 305,073 ms | 305,138 ms | Final stdout and exit 7 |
| Managed streaming foreground | 305,159 ms | 305,245 ms | Final stdout and exit 9; caller await expiry did not cancel work |

Each command actually slept for 305 seconds without output. Its explicit guest
budget was 330 seconds, with longer approved controller/client observation budgets.
The receive-idle setting was 120 seconds, so successful observation demonstrates
that the extended request did not inherit that shorter idle deadline. The managed
case renewed its lease, retained machine reservations after completion and released
them only after deletion. These were successful executions, not just acceptance of
a larger timeout field.

Separate real-worker cases on both platforms verified guest timeout exit 124 and
that a client observation timeout can leave a command running long enough to write
a file afterward. The durable disposable example additionally ran a quiet
305-second command on macOS, verified exit zero/output, and completed deletion
and reservation release.

The 24-hour limit is a finite policy/type bound. A 24-hour soak test was not run.
The measured long suites precede final tightening of background record and machine
observation validation. Those three changed files and both source snapshots are
identified in the evidence; deadline and observation code did not change afterward.
Final background acceptance and regression checks used the tightened implementation.

## Background HTTP acceptance

The updated durable example passed in two separate BEAM processes on **both
platforms**, using real PostgreSQL records and guest VMs:

1. Create a managed image machine with TCP host 28731 mapped to guest 8000.
2. Write a retained file and launch Python's HTTP server through `background: true`.
3. Receive a typed launch PID, then check readiness in another managed command.
4. Fetch the retained file through the mapped port while the service runs.
5. Exit the controller and start another BEAM using the same durable store.
6. Recover the same launch identity/PID without replay and reach the existing service.
7. Stop/start the machine, explicitly launch again under a new execution identity,
   and fetch the same retained file.
8. Delete, independently verify absence, verify numerical and SQL port reservation
   release, and verify that creation identity still deduplicates to its deleted record.

Final recovered PIDs were 190 on macOS and 492 on Linux. These are historical
launch evidence, not durable process identifiers. A separate real case on each
platform verified background user 65534, explicit environment and working directory.
It confirmed effects through a subsequent foreground command, not by interpreting
the launch acknowledgment as process completion.

## Other checks

| Check | Result |
|---|---|
| Deterministic suite | 301 passed, 23 real-runtime cases excluded |
| Quality pipeline | Format, warnings, locks, xref, Credo/ExSlop, clone budget, Credence and Dialyzer passed |
| Coverage | 93.75% against the unchanged 90% floor; measured before final additional strict-validation assertions |
| Language/runtime matrix | Full suite passed on Elixir 1.18.4 / OTP 27.3.4.15, 1.19.5 / OTP 28.5, 1.20.4 / OTP 28.5 and 1.20.4 / OTP 29.0.6 |
| PostgreSQL adapter contracts | 31 passed on each platform |
| Ordinary real-worker regressions | Nine macOS and fourteen Linux cases passed |
| Durable recovery | 25 macOS cases passed |
| Checkpoints | Three ordinary and three PostgreSQL-recovery macOS cases passed |
| Package consumers | Current and minimum supported dependencies passed using the same final implementation archive |
| Documentation | ExDoc and local links/fragments passed for 59 pages |
| CI tooling | 23 tests and checker canaries passed |
| Dependencies/examples | Root and PostgreSQL dependency audits; root, PostgreSQL and minimal-example Dialyzer passed |

Simulated tests cover malformed acknowledgments, forged record modes, exact PID
syntax, unsupported combinations, dispatch/result persistence faults, cancellation,
competing controllers, unknown blocking, ownership mismatch, stop/delete races and
explicit quiescent resolution. Historical codec shapes and fingerprints are tested
without adding new semantics to old records. These are not represented as live
worker failure injection. PostgreSQL contracts use a real database with simulated
worker observations.

Linux's complete durable recovery and checkpoint suites were not rerun in this
feature campaign. Their earlier qualification remains in its original report.
The new Linux durable HTTP acceptance, extended execution and ordinary regressions
are fresh evidence for this change.

## Initial failures and corrections

- Old tests encoded the former five-minute bound or constructed historical records
  with a new command field. They now check the explicit new bound and exact older
  wire shapes, including rejection of forged old envelopes.
- The first macOS long suite passed its three cases but failed the warning gate
  because of an unused alias. After removal, the full long suite passed with exit zero.
- Linux's initial 15-second receive budget expired during cold machine setup. The
  dedicated fixture now allows 120 seconds for receiving setup responses; the
  305-second quiet commands still exceed this interval. The corrected full suite passed.
- An ad hoc final Linux HTTP rerun used an artifact directory created before setting
  private permissions. The directory adapter rejected it before machine creation.
  Correcting those owned directory modes allowed both phases to pass.
- The isolated Linux guest had no external DNS for dependency fetching. The exact
  already-resolved Mint 1.10.1 source was copied into that disposable guest. No lock
  or dependency version changed.
- PostgreSQL-example Dialyzer initially used a stale local-dependency PLT lacking
  the new launch state. The existing `--force-check` workflow refreshed it and passed.
  Initial style and test-fixture findings were also corrected without weakening gates.

## Reproduction, cleanup and limits

Follow the [execution guide](long-running-exec.md) for command budgets, runnable
examples and the opt-in real-worker suite. In the prepared Linux lab,
`bash scripts/lab/long-running-exec.sh` runs the extended cases and durable HTTP
phases with a fresh attempt label.

The Linux campaign temporarily raised only the dedicated worker's lifetime from
300 to 900 seconds to permit real execution beyond five minutes. One CPU, 1.5 GiB
memory, 96 tasks, a 768 MiB cache, the private network namespace and the outer
45-minute VM deadline remained enforced. The worker deadline was restored to
300 seconds. Final inventories were empty and no qualification-account KVM file
descriptors remained. The outer VM was stopped, the baseline digest verified and
its disposable overlay reset. No unrelated physical-host services were modified.

The final macOS inventory was also empty. SQL queries retained the deleted machine
and launched execution history with zero reservations and no port-owner rows.
The private worker and PostgreSQL cluster were stopped, and the mapped listener
was absent. Existing artifacts and durable history were retained.

Background launch offers no supervisor, readiness guarantee, final exit/status/log
API, automatic replay, service restart or safe PID-based killing. Stopped machines
retain files, not running processes. Upgrades require coordinated readers and
adapters for codec v6 and `extended_execution: 1`; no SQL column migration is added.
