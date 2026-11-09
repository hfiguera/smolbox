# Embedded Port example

This source checkout supports public development Runtime admission. Read
[the setup guide](../../docs/embedded-port.md) first. The Elixir dependency alone
includes no native package and performs no downloads or Rust compilation.

Approve the helper package and offline artifact, then set:

- `SMOLBOX_EMBEDDED_PACKAGE`: absolute private package directory.
- `SMOLBOX_EMBEDDED_MANIFEST_SHA256`: approved SHA-256 of `package.json`.
- `SMOLBOX_EMBEDDED_DOMAIN_JSON`: private domain file with stable `target_id` and
  `generation` (32 lowercase hexadecimal characters).
- `SMOLBOX_EMBEDDED_ARTIFACT`: approved absolute `.smolmachine` path.
- `SMOLBOX_EMBEDDED_ARTIFACT_SHA256`: approved artifact SHA-256.

For a new dedicated SDK account, create the domain file once with mode `0600`,
choose a stable target ID and a random generation (`:crypto.strong_rand_bytes(16)`
encoded as lowercase hex). Set `SMOLBOX_EMBEDDED_INITIALIZE=true` only for explicit
first enrollment. An existing domain must use its original generation; do not
rotate it or run another SDK writer concurrently. Initialization defaults to false.

The configuration verifies the approved manifest digest and explicitly approves
its SDK descriptor. New Linux candidate builds advertise volumes and stopped
disk growth using a
platform-specific policy; macOS and older approved packages keep their own
descriptors. Capability advertisement is separate from ordinary exact-package
qualification. The latest growth descriptor still requires fresh public
stop-grow-start qualification.

The [latest scoped Linux evidence](../../docs/evidence/embedded-port-http-parity-public-volumes-40c7d3d.json)
covers source-controlled public mounted local-container workflows with Memory
and PostgreSQL storage on both toolchains. PostgreSQL prepare/resume uses
separate normally exited BEAMs with stable keys and artifact storage.
Wider source/platform/resource acceptance remains pending.
This basic lifecycle example does not configure a volume policy or run mounts;
see the setup guide for the additional explicit volume/root/store approvals.

Validate configuration without launching the helper:

```sh
MIX_ENV=prod mix run examples/embedded_port/config.example.exs
```

Run the complete public lifecycle with a **new** private run directory:

```sh
export SMOLBOX_EMBEDDED_RUN_DIRECTORY=/absolute/new-run-directory
MIX_ENV=prod mix run examples/embedded_port/scripts/run.exs
```

The example creates and deletes its disposable and retained machines. It verifies
Exit 7, transfers 1,048,593 binary bytes, drains new assignments while retained
commands continue, normally restarts only the Runtime, resumes with the control
version, and checks that all owned reservations are released. A successful run
writes `evidence.json`; receipt-bearing `private-records-*.json` files stay private.
Failures preserve those records before normal shutdown. Never fabricate receipts
from SDK inventory or replay an uncertain command.

For an approved package declaring `terminals: 1`, explicitly set
`SMOLBOX_EMBEDDED_TERMINAL=true` to include the ordinary managed terminal proof.
It opens one retained-image shell, verifies binary output and input, checks guest
PTY dimensions after resize, observes Exit 7 and releases the durable command
slot before normal machine cleanup. Only the owned guest PTY changes mode; the
host tty is untouched. Terminal transcripts stay out of durable records. The
evidence distinguishes this requested proof from a lifecycle-only run, and no
crash, forced termination or CLI-race campaign is selected.

The default store is **ephemeral Memory**. Full BEAM/store loss can strand VMs;
private forensic files are not a store backup or restore API. For a durable host,
use `SmolBox.Example.EmbeddedPort.run/3` with `store: {adapter, context}`,
`mode: :durable` and a stable `fingerprint_key`; start that store before the example.
The example can also accept `http_workers: [...]` to exercise separately configured
HTTP workers while the native target drains. These workers require separate SDK
accounts or domains from the embedded helper.

Live process interruption testing and native distribution signing/source delivery
remain outside this development example. Rustler and Kubernetes are not implemented.

## Ordinary mounted-volume qualification

The public package consumer accepts `--native-volume` with explicit
`--native-public`, `--without-rust` and `--native-volume-root /absolute/canonical/root`,
alongside its usual package, artifact, domain, output and report options. It runs
separately from terminal, network and workload campaigns. The package must declare
Linux volume descriptor one. This source-controlled workflow adds competing
attachment rejection to the earlier private witness and keeps the original
Runtime/store alive on unexpected outcomes. It selects no interruption campaign.

`SmolBox.Example.EmbeddedVolumes.run/3` defaults to a single Memory-backed run.
An injected durable `store`, `mode: :durable` and stable 32-byte `fingerprint_key`
also support `phase: :prepare` and `phase: :resume` in separate normally exited
BEAMs. Both phases require the same explicitly configured `artifact_root`; resume
checks an output collected before shutdown as well as retained guest data. Resume
requires `expected_records` pointing to prepare's private
`private-records-before-replacement.json`. That file supplies assertions only:
backend authority always comes from the store. These new runner paths still need
their own exact-package physical acceptance.

The durable example's `scripts/embedded-volumes.exs` requires explicit
`--ordinary --without-rust --settings /private/settings.json --phase prepare|resume
--output /private/new-output`, plus `--expected-records` for resume. Run from the
durable example after its existing database setup and migrations. Settings contain
`package`, `manifest_sha256`, `artifact`, `artifact_sha256`, `domain_json`,
`volume_root`, `partition`, `scope`, `encryption_key_file`, `fingerprint_key_file`
and `artifact_root`. Keep the database partition, keys, scope, domain and artifact
directory stable across the pair. Prepare intentionally retains a normally
stopped machine and attached volume; resume verifies their original authority
and finishes owned cleanup. Use a new scope for a subsequent completed pair.

On an unresolved run, atomically publish mode-0600 `control.json` in its private
output directory. A request such as `{"request_id":"status1","action":"status"}`
gets a private result file. Each lowercase-alphanumeric request ID is consumed
once. `stop_machine`, `delete_machine` and `delete_volume` also require a known
workflow `id` and its exact inspected `version`. Mutations are never replayed by
this receiver. `close` succeeds only after all workflow machines/volumes are
deleted or absent and the worker has zero slot/disk reservations. Unknown outcomes
remain retained; checkpoint files are not a store restore or adoption mechanism.

Current-toolchain consumer and PostgreSQL 16.15 prepare/resume acceptance is
recorded in the [scoped evidence](../../docs/evidence/embedded-port-http-parity-postgresql-volumes-1fd1262.json).
The minimum PostgreSQL attempt exposes a reconciliation gate rejecting sibling
deletion before dispatch. Positive create/delete checks now retry that admission
only within a finite bound and after verifying no accepted intent or an exactly
unchanged volume record. Entered/uncertain mutations, changed records and expected
negative quota/drain cases are not retried. Physical acceptance of this latest
guard, the minimum durable pair and the new minimum Memory consumer remain pending.


For a separately approved Linux package declaring `disk_growth: 1`, the explicit
public consumer campaign is `--native-public --native-growth --without-rust`
with the usual package/fixture/domain/output arguments. It selects only the
source-controlled `growth_demo.ex` and `growth_control.ex` workflow; do not combine
it with the volume, terminal, network or workload campaigns. The workflow
qualifies unmounted stopped growth, original creation authority, full disk
reservations, duplicate/conflicting intents, drain rejection, retained binary
data, measured workspace filesystem size and normal stopped Runtime replacement.
The bounded filesystem probe uses POSIX shell, `df -Pk`, `awk` and `sleep`, provided
by both the approved packed workload and BusyBox bare fixtures. It does not require
Python, accept malformed/missing measurements, or replace measurements with the
managed disk-size fields. A successful probe records `workspace_bytes` in its
bounded command output. Bare boot/growth needs its own ordinary acceptance.
The overlay is checked through physical geometry/proof and managed observations;
this container witness does not measure a bare guest overlay filesystem.

The durable launcher is
`examples/durable_host/scripts/embedded-growth.exs`. It requires explicit
`--ordinary --without-rust --phase prepare|resume --settings PRIVATE_JSON --output NEW_DIRECTORY`.
Use the durable-volume settings shape with the exact approved growth package,
a fresh scope and stable store partition, encryption/fingerprint keys and artifact
root; no volume root is used. Resume additionally requires `--expected-records`
pointing to prepare's private before-replacement checkpoint. That file supplies
comparisons only; encrypted database records remain authoritative.

To qualify another fixture in the same durable partition, retain the complete
approved `artifacts` catalog in settings and select the new entry with
`artifact_id`. Each catalog entry uses the normal native approval fields: `id`,
`path`, `sha256`, `architecture` and `max_bytes`. Keep previous entries unchanged,
including the original `application` approval. Multiple entries require explicit
selection; an unknown or duplicate selected ID fails before workflow startup.
Existing single-artifact `artifact`/`artifact_sha256` settings retain their default.

The workflow module also accepts `source_id` to select one existing approved OCI
or registry entry from `target.sources`. Keep the source catalog and any registry
cache policy in the supplied Config. `configure(target, network: policy)` supplies
an explicit network profile for OCI; the default remains offline. Mixing non-nil
`artifact_id` and `source_id`, ambiguous/unknown IDs or OCI with an offline profile
fails before output/owner startup. Existing local artifact selection is unchanged.
Evidence keeps the chosen `creation_input`; remote manifests are not labeled as
local `fixture_sha256` blobs.

The public consumer optionally accepts `--native-growth-settings /absolute/private.json`.
The consumer copies and hashes this owned regular file (maximum 65,536 bytes,
no group/other permissions) with its frozen proof tooling. Omit the option for the
existing local default. The growth proof also accepts the copied file as `--settings`.
Its exact top-level fields are `sources`, `source_id`, `artifact_id`, `network`
and `cache_policy`; unknown fields reject before workflow startup. For example,
an OCI approval uses this shape (replace the sample with an approved platform
manifest; no tag or index resolution is implied):

```json
{
  "sources": [{
    "kind": "oci",
    "id": "approved-image",
    "reference": "registry.example/team/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "architecture": "x86_64"
  }],
  "source_id": "approved-image",
  "network": {"hosts": ["registry.example"], "cidrs": []}
}
```

Allow the actual approved registry and layer endpoints in `network`. Registry
artifact entries instead use `kind: "registry"` with `content_sha256` identifying
the prepared `.smolmachine` blob, and require a `cache_policy` containing
`max_download_bytes`, `max_cache_bytes` and `max_cache_files`. A registry entry
may carry a safe `credential_ref`; `cache_policy.token_realms` maps those references
to exact approved HTTPS exchange endpoints. Token values belong in the host's
credential resolver, outside settings and evidence. Guest networking stays offline
unless explicitly approved with `network`; host download allowance is separate.

The durable settings file accepts the same five fields alongside its existing
store/package/domain/key settings and now enforces the same private-file bound.
Retain the complete `artifacts` catalog (or the legacy single-artifact fields)
in both prepare and resume. For an explicitly remote-only fresh domain, supply
`artifacts: []`. Existing typed sources are retained; settings may add approvals
but cannot replace an existing ID or registry policy. Resume must retain the same
source, network, cache allowances and all earlier approvals. The recorded
[Linux OCI/Memory cases](../../docs/evidence/embedded-port-http-parity-linux-oci-growth-ff0ed3e.json)
pass on the exact ff0ed3e/5cd0cb21 public client and e7387c9c native package on both
toolchains. The later [remote-source cases](../../docs/evidence/embedded-port-http-parity-linux-source-growth-3cf8086.json)
pass OCI/PostgreSQL prepare/resume on frozen ff0ed3e path source and registry/Memory
on actual 3cf8086/9221a9cf public consumers, both current/minimum. SQL authority and
original keys survive a normal BEAM restart; registry bearer access has exact
single-preparation counts. Later rotated-token consumption is not qualified.
Registry durable growth, current packed/mounted and other required combinations,
and the remaining full-parity gates still need qualification.

An unexpected result retains the original owner and private records. The growth
control receiver accepts private once-only status/close requests and exact-version
stop/delete for `original`. Explicit `resolve_growth` requires the known
`first`/`second` intent, current version and `quiesced: true`; it never performs
another resize or repairs a partial disk. Do not terminate the parked owner or
treat caller timeout as collection. Closing checks positive owned deletion and
zero reservations. These runners introduce no crash campaign. Ordinary acceptance
is limited to the exact packages, sources, stores and platforms linked above;
changed bytes and other required combinations still need their own qualification.

The image and growth workflows additionally accept `stop_owned_machine`, with
the exact current `version`. Images allow `original` or `warm`; growth allows
only `original` in its configured scope. Both use the shared `owned_control.ex`
implementation. Use it only for an unknown machine blocked by retained work.
It freezes coordinator dispatch, drains the original helper epoch and sends normal stop with the saved creation receipt.
The owner and store records stay alive. An unconfirmed stop remains uncertain;
this action supplies no command exit and releases no reservation. Once stopped
ownership is verified, resolve explicitly, wait for the worker to become ready,
and submit exact-version deletion. A busy helper is never bypassed or signalled.
This control is model-tested; ordinary live acceptance remains pending.

The branch example's private control receiver also exposes the existing
`collect_partial`, `publish_collected`, `dispose_partial` and `cleanup_partial`
APIs. It also accepts `resolve_deleted`, forwarding
`Branches.resolve(..., quiesced: true, disposition: :deleted)` for the same
original child. Each request needs a unique `request_id`, the original child ID
(`first` or `held`), its current `version`, and `quiesced: true`. Use a status request to
read the version before issuing an action. The Runtime still checks the saved
authority, current branch phase and native proofs; collection or publication
alone does not release reservations. Deleted resolution requires the existing
native phase/ownership proofs and positive original-disposal or absence evidence;
it never derives ownership from an SDK name or current inventory. Rejections
include category, operation and dispatch evidence. No process-signalling or supplied path/PID commands are
accepted. These control routes are model-tested; ordinary partial-recovery
qualification remains pending. See [managed branches](../../docs/managed-branches.md).

The keeper also accepts `resolve_machine` with the original `id`, current `version`
and explicit `quiesced: true` after the caller has established safe stopped
ownership. It forwards the existing `Machines.resolve` API; it never replays start
or resize, and a running/unverified machine is not resolved as stopped.

### Ordinary macOS saved-state consumers

Explicit current macOS packages advertise `checkpoints: 1`, `branches: 1` and
`partial_collection_preflight: 1`. Older approved packages keep their smaller
feature surface. Bare sources must satisfy the same idle/offline restrictions
as the HTTP backend; container artifacts are unsuitable for these workflows.

Use the public package consumer's separate `--native-branches` or
`--native-checkpoints` campaign with `--native-public --without-rust` and the
usual approved package, bare fixture, digest, domain and fresh output arguments.
The checkpoint campaign captures RAM/disks, confirms quiescence, stops the source,
normally replaces Runtime while retaining Memory, registers the exact captured
approval and checks two independent restores. It explicitly removes capture bytes
and releases native staging/accounting after deleting all machines. The branch
campaign checks sibling isolation, held release, cold restart, admission/drain
and paired backing release. Neither campaign interrupts an owner.

Failures retain the original Runtime/store and private control receiver. The
checkpoint receiver accepts `resolve_capture` (`quiesced: true`) and
`release_capture` (`artifacts_removed: true`) only for `source` and its fixed
`prepared` capture, with the current machine version and unique request ID.
These controls do not assert quiescence or remove artifacts on the host's behalf.
The [scoped current/minimum Mac branch consumers](../../docs/evidence/embedded-port-http-parity-macos-public-branches-f1af384d.json)
pass these ordinary branch checks on manifest 8bb60295/helper 09ea5c46.
The [later current/minimum checkpoint and branch consumers](../../docs/evidence/embedded-port-http-parity-macos-public-saved-state-f8f8156e.json)
pass basic-seed capture, continued source state, two independent restores, normal
stopped Runtime replacement, cold restart and complete owned/artifact cleanup on
manifest b7851d7e with the corrected f8f8156e Elixir package.
Wider parity gates remain open; crash validation stays deferred.

Future branch keepers also expose the existing `Machines.collect_deletion`,
`continue_deletion` and `cleanup_deletion` APIs under those exact action names,
with a child ID, current version and `quiesced: true`. These are distinct accepted
requests; an entered SDK deletion is never replayed. Updating these source files
does not change an already running keeper.

The checkpoint consumer additionally requires `--native-checkpoint-seed` and
`--native-checkpoint-seed-sha256`, naming an explicitly prepared dependency-free
`.smolcheckpoint`. It keeps the seed approved during normal Runtime replacement.
SDK 1.22 records a pack reference even when a `.smolmachine` contains a bare VM;
that source remains eligible for branching, but cannot produce a self-contained
portable capture. Native capture preflight rejects it before SDK entry.

`native/smolbox-engine/examples/prepare_checkpoint_fixture.rs` is an opt-in input
preparation tool for a fresh dedicated account, using ordinary unmodified SDK
create/start/capture/stop/delete APIs. It is never included in the consumer
package or used as a backend fallback. Fixture preparation is separate from
public Port acceptance; crash validation remains deferred.

On macOS the preparer uses the SDK's sparse raw-disk seeding API and makes only
its newly cloned private disks owner-writable before boot. Read-only input
templates and the approved package retain their bytes and permissions. Its report
requires a basic device profile, no packed dependency, normal stop/deletion and
empty SDK inventory; a failed preparation retains its original SDK Runtime for
explicit same-owner cleanup.
