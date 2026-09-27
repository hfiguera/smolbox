# Images and registry artifacts qualification

This is development qualification against smolvm **1.19.0**, performed on Linux
x86_64 with KVM and macOS Apple Silicon. It does not certify arbitrary registries,
host quotas or hostile multi-tenant isolation. No supported runtime upgrade or
relaxation of isolation or egress controls was required.

## Real workers

The [sanitized evidence](evidence/images-and-registry-artifacts.json) records the
source manifests, prepared content digests, returned image configuration digests,
inventories and final deletion evidence. PostgreSQL stored encrypted records.
Controller recovery used separate BEAM invocations, not an in-memory simulation.

| Scenario | Linux x86_64 | macOS Apple Silicon |
| --- | --- | --- |
| Registry artifact warm with isolated cache | Cold and warm observed | Cold observed |
| Approved registry create, write, controller recovery, read | Passed | Passed |
| Same machine stop/start, retained file, delete/absence, reservation release | Passed | Passed |
| OCI creation from an approved platform manifest | Passed | Passed |
| Cold managed pull of a different OCI image | Passed; inventory grew from 1 to 2 | Passed; inventory grew from 1 to 2 |
| Original file survives image pull, controller recovery and stop/start | Passed | Passed |
| Stopped image listing does not start the VM | Passed in low-level campaign | Not separately qualified |
| Low-level pull implicitly starts a stopped OCI VM | Observed; managed API rejects stopped machines | Not separately qualified |

The Linux registry acceptance began with a new empty worker cache. It warmed a
fixture containing Alpine, wrote `/workspace/retained.txt`, exited its BEAM,
reconnected using the same PostgreSQL identity, read the file, stopped and started
the same machine, read again, then verified absence and zero reserved resources.

The public `SmolBox.DurableHost.RegistryDemo` was also run on both platforms. The
OCI campaign created Alpine from its platform manifest, pulled a different pinned
BusyBox image and compared the returned configuration digest with that manifest's
config descriptor. The final phase recovered the original specification, read the
original file and performed the same stop/start/delete checks.

An early live probe attempted a pull on a prepared-artifact machine. Upstream
returned synthetic metadata instead of a real download. The strict client rejected
the response, leaving an unknown operation. After shutting down the original
controllers and worker server, the replacement server stopped the verified VM;
explicit quiescent resolution preserved the unknown outcome. Both machines then
passed file reads and deletion. The final managed API rejects this use before
dispatch. This limitation is covered by regression tests.

## Reproduce

Use isolated worker data, a dedicated PostgreSQL partition and persistent private
keys. Do not clear shared caches. Start the qualified official worker and follow
the [durable example instructions](https://github.com/hfiguera/smolbox/tree/main/examples/durable_host#registry-artifacts-and-machine-images).
Run registry `prepare` and `resume` as separate processes. Check that the first
preparation reports `already_cached: false` when qualifying a cold cache.
On Linux, `SMOLVM_DATA_DIR` relocates the worker and cache. In smolvm 1.19.0 that
setting is a no-op on macOS: use an isolated process home instead, with a short
absolute path to stay within Unix socket path limits. Do not mistake a new VM
directory for an empty registry cache.

For a local prepared-artifact fixture, `test/support/registry_fixture.py` serves
one existing `.smolmachine` on worker-host loopback and writes its immutable
manifest/content identity to the specified output file. It is test infrastructure,
not a production registry or an image publishing API. Use `--artifact FILE
--output IDENTITY.json`; stop that owned fixture after qualification.

Use a new identity for the OCI campaign. Supply an explicit operator network
allowlist and approved platform manifests for creation and pull, then run
`prepare`, `images`, and `resume`. Neither the example nor SmolBox silently opens
network destinations to make downloads succeed. Delete only the owned test
machines and verify worker inventory and store usage afterward.

## Simulated coverage and limitations

Protocol and fault tests cover canonical references, platform/digest mismatch,
approval rejection, deduplication/conflicts, credentials and redaction, uncertain
responses, bounded preparation, ownership mismatch, competing controllers,
cancellation and store interruption around preparation and dispatch. Shared store
contracts run against memory and real PostgreSQL, including immutable preparation,
cache exclusion across lease expiry, typed image results and retained reservations.

No operator-provided authenticated registry was available. Explicit identity-token
propagation, rotation, failure handling and redaction are simulated protocol tests;
they are **not** real authenticated-registry qualification. The loopback fixture
is unauthenticated; public OCI pulls use upstream's public-registry access flow.
Explicit identity tokens on private/loopback registry targets are rejected upstream.

No cache-hit rehashing, shared cache quota, automatic eviction, cross-store cache
coordination or lost-disk recovery is claimed. OCI source constructors require an
operator-selected platform manifest; they cannot infer index versus manifest
semantics from a digest string alone. See the
[feature guide](images-and-registry-artifacts.md) for these boundaries and codec
v10 upgrade and rollback requirements.

Repository validation passed: 425 library tests/doctests/properties, 41 PostgreSQL
example tests, formatting, compilation with warnings as errors, zero dependency
cycles, Credo, duplicate-code checks, Credence, Dialyzer and ExDoc with warnings as
errors. The minimal host compiled; it defines no tests. The 29 existing runtime
tests excluded by the default suite are not counted as live evidence; the real
worker scenarios described above were run separately.
