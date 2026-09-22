# Port-mapping validation

Development-host validation on September 22, 2026, for
`feature/managed-port-mappings`, based on `e6396fd647dc25bc99c72d39a6062d3d6a1686f0`.
This is implementation evidence, not production-isolation certification.
The [machine-readable report](evidence/port-mappings.json) records source hashes,
runtime and artifact identities, HTTP acceptance output and cleanup evidence.

## Real workers

Both platforms ran official smolvm **1.17.0** distributions. The inspected upstream
checkout was `73d4b480dc703c86b676bb54f72318ef94f24e6a`, whose tree
`493f7d59f6d7e2c024c1854b151e4875ff93ccd3` matches release commit
`d33b5a4adeb844365922cd2a29a89d93a94008ad`.

| Input | macOS | Linux |
|---|---|---|
| Host | Native Apple Silicon, macOS 26.6.2 / 25G83 | Disposable nested KVM, Ubuntu 24.04.4, x86_64, kernel 6.8.0-139-generic |
| PostgreSQL | Private PostgreSQL 17 cluster | PostgreSQL 16.15 inside the disposable VM |
| Toolchain | Elixir 1.20.4 / OTP 29.0.6 | Elixir 1.20.4 / OTP 29.0.6 |
| smolvm binary SHA-256 | `bee762e648f2c90e2339c6c3f37d6fd47d3645888e2b4d73963e511032d2195a` | `40b9bc8f24f7cc77c371db4784742e6b6724f09a11b83d63776b944734b7912d` |
| Python artifact SHA-256 | `bb3ed187bc4cfc1cc6f7e4e09c8f96ac1c2d47dcd2902653e6c1bd2ba6ca017c` | `76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2` |

The Linux worker used its existing one-CPU, 1.5 GiB memory, 96-task limits,
768 MiB cache mount, private network namespace and 300-second per-run deadline.
The outer disposable VM has a 45-minute deadline. Tests did not run against
unrelated services on the physical `ssh linux` host. The HTTP controller joined
the worker's network namespace as the unprivileged lab user, so worker-loopback
reachability was tested without widening listener exposure.

## HTTP acceptance

The two-process PostgreSQL example passed on **both platforms**:

1. Create a managed machine with TCP host 28731 mapped to guest 8000.
2. Write `/workspace/retained.txt` in one command, then start the guest HTTP server
   in another, with independent execution identities and guest readiness checks.
3. Read the file through the worker host's mapped HTTP port.
4. Exit the first BEAM; a second BEAM loads the same machine/mapping from the same
   PostgreSQL partition and reaches the already-running service.
5. Stop/start that machine, explicitly restart the guest server, and read the same
   retained file through the same mapping.
6. Explicitly delete, independently verify worker absence, verify zero numerical
   capacity and port reservations, and prove the old creation ID still deduplicates
   to its deleted record.

The test does not assume a guest process survives VM stop/start. SQL port-owner
rows were checked directly in addition to inspecting the managed record.

## Additional validation

| Check | Evidence |
|---|---|
| Full deterministic suite and ordinary quality pipeline | 285 passed; format, warnings, dependency-lock check, zero xref cycles, Credo/ExSlop, zero clone budget, Credence and Dialyzer passed |
| Coverage | Separate 284-case run: 93.51%, above the unchanged 90% threshold; the later runtime-version admission case also passed |
| PostgreSQL adapter contracts | 31 passed on each platform, including cross-partition port contention, partial-allocation rollback and projection corruption |
| Port-specific real-worker cases | Two passed on each platform: inbound HTTP with denied/allowlisted outbound, and external socket conflicts on initial start and restart |
| Ordinary real-worker regressions | Nine macOS cases and fourteen Linux cases passed; Linux includes the existing security suite |
| Durable recovery regressions | 25 cases passed on each platform |
| Checkpoint compatibility | Three ordinary and three PostgreSQL-recovery cases passed on each platform |
| Persistence compatibility | Exact v4 assigned-machine and command evidence loads with empty port defaults; original no-port fingerprints preserved; forged schema shapes rejected |
| Rollback guard | A real PostgreSQL rollback attempt was rejected while managed identities remained; schema and ownership table stayed intact |
| Minimum language/runtime | Full suite passed on Elixir 1.18.4 / OTP 27.3.4.15, 1.19.5 / OTP 28.5, 1.20.4 / OTP 28.5, and 1.20.4 / OTP 29.0.6 |
| Documentation and packages | ExDoc generation and local-link checks passed for 56 pages; current and minimum-dependency package consumers passed |
| Tooling and dependencies | 23 CI-tool tests and checker canaries passed; root and durable-example dependency/security audits passed |

The simulated tests exercise mapping mismatches, uncertain replies, missing VMs,
store failure, unknown-command blocking, stop/delete races and controller restart.
These are not claimed as real-worker failure injection. PostgreSQL contract tests
use a real database; their machine observations are simulated. The HTTP example,
port socket conflicts, outbound probes and runtime regression suites use real VMs.

For outbound probes, both destinations first passed host-side positive controls.
Linux used local responders at 198.18.0.10 and 198.18.0.11 inside the isolated
namespace. macOS used a resolved example.com address and 1.1.1.1 on TCP 443.
With `:offline`, both guest connections failed while inbound HTTP worked; with a
single-IP CIDR allowlist, only the approved guest connection succeeded. The final
port tests inspect actual OS listener addresses and probe IPv6 HTTP when its
best-effort listener exists. Both platforms confirmed `127.0.0.1` and `::1`, including HTTP through IPv6.

## Initial failures and corrections

- Old temporary macOS image paths no longer existed. The first HTTP attempt failed
  before machine creation. Fresh Python/Node images were prepared in the private
  directory with a bounded process and disk guard; their hashes are recorded.
- Legacy codec tests initially expected v4 writes and constructed historical
  records with new fields. They now assert v5 writes and exact legacy shapes;
  assigned ownership and no-port identity preservation were added explicitly.
- Linux initially reported `:eaddrinuse` while the conflict test attempted to bind
  immediately after a stopped observation. The fixture now requires actual socket
  release within five seconds before installing the unrelated listener. It still
  requires the worker's typed conflict and unchanged mapping on both starts.
- A new simulated conflict test raced a reconciliation version update before
  deletion. It now waits for that recorded update; the version guard is unchanged.
- Initial style/complexity and function-clause ordering findings were corrected.
  No coverage floor, resource limit or behavioral assertion was weakened.

## Reproduce and limits

Use the [HTTP example instructions](port-mappings.md#runnable-http-acceptance-example).
Within the prepared disposable Linux lab, `bash scripts/lab/port-mappings.sh`
sets up bounded, isolated responders and runs the port tests plus both HTTP phases.
It requires the installed qualified 1.17.0 candidate. Set `SMOLBOX_PORT_ATTEMPT`
to a fresh lowercase alphanumeric label for another run; each label owns a new
report directory, execution identity and database partition. Existing labels are
not overwritten.

The port suite is separate from `test/runtime` so existing ordinary-worker jobs
do not silently acquire new network-fixture requirements. To run it elsewhere,
set the normal worker/image variables plus `SMOLBOX_PORT_ALLOWED_IP`,
`SMOLBOX_PORT_DENIED_IP` and `SMOLBOX_PORT_OUTBOUND_PORT`, then run
`mix test test/ports_runtime --include runtime --warnings-as-errors`. Both addresses
must be reachable directly from the test process. Reserve host ports 28732/28733
for this suite and run it where the worker's loopback namespace is visible.

Default loopback forwarding is qualified here. Worker-wide widened binding remains
deployment configuration documented from upstream source; no public-internet,
firewall, TLS, authentication, UDP, automatic allocation, migration, lost-disk
recovery, production isolation or cross-version checkpoint qualification is claimed.
Final worker inventories, reservation counts and process cleanup are recorded in
the evidence report. Raw private lab directories contain credentials and are not
published as artifacts.

The disposable/checkpoint Linux regression snapshot preceded the final public
managed-machine capability guard. Its relevant implementation was unchanged;
the final managed HTTP/port run used the current library and adapter hashes in
the report. Both snapshots are recorded to avoid conflating source identities.
The final Linux worker and outer VM were stopped, baseline integrity verified,
and the disposable overlay reset only after exporting evidence. The private
macOS worker and PostgreSQL were stopped; dedicated ports had no remaining
listeners. Managed deletion history was verified before lab teardown.
