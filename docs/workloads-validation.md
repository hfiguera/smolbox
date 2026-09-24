# Workload configuration and console validation

The unreleased feature passed **development qualification** on smolvm 1.17.0
on Linux x86_64 and macOS Apple Silicon (2026-09-24 UTC). It exposes immutable
startup configuration and console-only diagnostics. Automatic restart policies
remain rejected. See [the guide](workloads.md) for the public contract and
[machine-readable evidence](evidence/workloads.json) for input and receipt hashes.

## Source and reproducibility

The branch started at `e2f90267b06ec6d039882915a447c19465a32b1c` with working-tree
feature changes. The Linux input archive SHA-256 is
`744fd2c5011f484ebdc55c7e39daad62f6389368d5a0546bdbecf80cc030d2e1`.
All 523 archived files were checked against the guest tree; only the documented
`WorkloadDemo` correction was overlaid. The final library file manifest digest
is `d19ad9b0ca44b62d3339558e87129324ff0f70b5191ed8377e47ed76a38a6c71`.
The evidence records that overlay hash separately. Later test and documentation
edits do not change the library used by these real-worker campaigns.

The reference repository was smolvm `73d4b480`, v1.17.0. Linux used the official
x86_64 archive and the approved Python artifact; their hashes are in the receipt.
macOS used the previously qualified native 1.17.0 runtime and approved native
Python artifact. No upstream source changes were made.

## Real-worker evidence

Both platforms ran `test/workload_runtime` and the PostgreSQL example in
`examples/durable_host/scripts/workload.exs`, using separate `prepare` and `resume`
BEAM processes with the same partition and keys.

| Check | Linux | macOS |
| --- | --- | --- |
| Explicit entrypoint, command, environment and working directory | Passed | Passed |
| Separate command reads startup-written persistent file | Passed | Passed |
| Fresh controller reconnects without a second startup | Passed | Passed |
| Stop/start preserves the file and produces the second startup | Passed | Passed |
| Console snapshot and bounded follow deliver events | Passed | Passed |
| Missing startup executable still permits a running VM and later exec | Passed | Passed |
| Explicit deletion, observed absence and released disk/slot reservations | Passed | Passed |
| PostgreSQL store suite, including v8 intent preservation | 33 passed | 33 passed |
| Final owned machine inventory | Empty | Empty |

Linux used the disposable nested KVM lab accessed through `ssh linux`. The worker
retained its five-minute deadline, one CPU quota, 1.5 GiB memory and 96-task bound.
The successful campaign took about 55 seconds, recorded zero OOM kills, stopped
the worker and observed no remaining owned KVM descriptors. The outer lab was
stopped and its automatic reset verified against the baseline checksum and a
clean overlay. Phase output was captured and synced to the physical host before
reset; exported hashes still matched afterward. The macOS private worker and
PostgreSQL server were stopped after qualification; its CLI inventory was empty.

The first Linux example failed a test assertion, not startup: the console includes
startup command text, so finding the print marker inside that text did not prove
stdout capture. The example now constructs a distinct output marker and checks
for an actual output line. The failed and successful capture receipts are both
retained. Application stdout/stderr remain unavailable; diagnostic console content
can itself contain sensitive arguments. macOS's first example Dialyzer invocation
used a stale dependency PLT; a forced check refreshed it and passed with zero
errors.

## Simulated and build checks

The final simulated coverage run passed **350 tests** (including four doctests and
six properties), with **93.11% library coverage**; 27 opt-in runtime tests were
excluded. Focused tests cover wire configuration, nil defaults, invalid restart
policies, immutable identity, v4/v5/v6 compatibility, v8 rejection in old envelopes,
shared store preservation, controller recovery, ownership mismatch, store failure,
log absence without machine absence, fragmentation, malformed SSE, byte/frame/event
limits, callback exceptions, deadlines, unsupported versions and no HTTP retries.
These peers do not simulate application execution and are not real-worker evidence.

`mix ci` passed, including formatting, compilation with warnings as errors, xref,
tests, Credo, clone detection, Credence and Dialyzer. Two subsequent edge tests were
included in the final 350-test coverage run; static checks were repeated afterward.
The PostgreSQL example passed Dialyzer. The focused workload, codec, port-compatibility
and log tests also passed on Elixir 1.18.4 / OTP 27.3.4.15 (21 tests). ExDoc generated without warnings and its
local links were checked. Package consumers passed with current and minimum
supported dependencies, including workload construction and codec-v8 round trips.

This does not qualify automatic restart supervision, application stream capture,
production isolation, throughput, durable stream replay or log retention. No
application readiness signal is inferred from a VM state or console event.
