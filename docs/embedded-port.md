# Embedded Port setup and operation

The embedded Port bridge is available for development through the public
`SmolBox.Runtime` API in this source checkout. There is no published native package.
A separately approved helper runs locally under Elixir supervision. Existing HTTP
workers can be used in the same Runtime.
Rustler is a future additional bridge; Kubernetes is a separate future backend.

The migration to an unmodified SDK has removed the five active downstream patches
while keeping this architecture. Repository design and implementation notes are
`docs/design/embedded-port-unmodified-sdk.md` and
`docs/design/embedded-port-unmodified-sdk-implementation-plan.md`.
Crash validation stays deferred. Exact clean development packages have ordinary
platform and current/minimum consumer qualification on Linux x86_64 and macOS arm64.
Existing approved patched-package evidence remains
historical and cannot approve their bytes.

## Package and host preparation

The Hex package contains Elixir code. A separately approved native package contains
the helper, libraries, root filesystem, disk templates and manifest. Consumers do
not need Rust. Maintainers build it with `native/package.py` from the verified SDK
source described in `native/vendor/source.json`.

Qualified development hosts are Linux x86_64 with accessible `/dev/kvm` and macOS
arm64 with the hypervisor entitlement. Prepare approved offline `.smolmachine`
artifacts and the manifest's digest-pinned `resize2fs` tool. Preserve asset modes
when extracting (`tar --same-permissions` on Linux). Install at a private absolute
path. Approve the exact manifest digest and its complete identity tuple through
your trusted release channel; computing a digest does not authenticate a publisher.

During the unmodified-SDK migration, newly built helpers prepare approved sparse
plain templates in the dedicated account's `~/.smolvm` before readiness. Conflicting
plain or compressed templates in home, helper or boot directories prevent
activation; they are never overwritten. Keep account templates and their
package/domain references when removing a package. Maintainer package authoring
requires `zstd` to regenerate compressed assets from the resized plain templates;
prebuilt-package consumers do not need it. Existing approved packages retain their
historical behavior and identities until replaced through the migration workflow.

Package rebuilds preserve already approved 1-GiB template bytes when their ext4
geometry matches; rerunning the resize tool can otherwise change the digest even
at the same size. Creation completes formatting through the clean SDK's public
disk API before making newly owned backing files private and writable. Approved
templates remain immutable. Transfer spools use private directories independently
of the account's default umask; only verified owned directories beneath the
enrolled domain may have older readable permissions tightened.

Use a dedicated OS account and the SDK's default data paths. Arbitrary database
paths are unsupported. Persist the stable target ID and domain generation. Initial
enrollment requires explicit `allow_initialize: true`; normal use keeps it false.
Never rotate the generation to repair an error. Do not run independent SDK tools,
another helper, or a future Rustler bridge concurrently against this domain.

`SmolBox.Embedded.Config.new/1` validates explicit package identity, manifest digest,
domain binding, approved artifacts, offline profiles, capacity and allocation floor.
Capacity declarations are admission policy, not host-enforced quotas. The repository
example at `examples/embedded_port/config.example.exs` validates this configuration
without launching a helper. Pass the resulting target in the Runtime `:workers`
list to launch the Port bridge.

## Supported development surface

| Operation | Qualification scope |
| --- | --- |
| Create, inspect, start, stop, delete | Full authenticated creation intent and receipt; name alone never authorizes cleanup |
| Foreground execution | Argument vector, environment, work directory and numeric container UID; observed Exit is authoritative |
| Files | Bounded reads and atomic bounded writes; rejected partial upload leaves existing bytes intact |
| Retention | Exact bytes survive normal stop/start and stopped-helper replacement |
| Cancellation | Stops the request/subscription; does not promise guest process termination |
| Output budgets | Finite output cap and acknowledgement credit; sibling requests remain usable |
| Draining | Worker drain fences new assignments; existing retained commands and lifecycle operations continue. Helper quiescence separately fences mutations during replacement |

Network access, interactive stdin, background execution, port mappings, host mounts,
checkpoint/export and branch workflows are not qualified for this bridge. Profiles
are offline. The VM pack does not accept an explicit guest user; the execution
container's numeric UID is separate. Unknown outcomes must be inspected and
reconciled, never replayed automatically.

## Public application startup

Configure at most one embedded target per BEAM node. The store must advertise
`backend_bindings: 1`, `backend_recovery: 1` and `managed_machines: 1`, with the
matching callbacks. Store negotiation and domain binding happen before helper
activation. A mismatched manifest, domain, handshake or recovery record keeps
admission closed. The HTTP client configuration remains unchanged.

Clean manifest schema 2 binds protocol 1.4 and SmolBox's ownership, observation,
worker, asset and boot-guard policies. The bridge requires at least 4000 ms of
cancellation grace for this version (the default). An epoch-bound unavailable
notice closes admission while retaining the current helper, pending results and
reserved capacity. It does not initiate replacement or prove cleanup. Approved
legacy schema 1 / protocol 1.3 packages retain their original handshake limits;
they cannot transfer authority to a clean package.

For local development, with `target` returned by the configuration example and
an explicitly configured artifact store:

```elixir
children = [
  {SmolBox.Store.Memory, name: MyApp.Store},
  {SmolBox,
   name: MyApp.Runtime,
   namespace: "myapp",
   mode: :ephemeral,
   store: {SmolBox.Store.Memory, MyApp.Store},
   artifact_store: artifact_store,
   fingerprint_key: fingerprint_key,
   workers: [target]}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

Use a 32-byte fingerprint key. A durable application must preserve that key and
its native domain binding, use a durable store implementing the required callbacks,
and select `mode: :durable`. The PostgreSQL example adapter supplies these
capabilities; apply all its migrations before startup. Memory is explicitly
**ephemeral**: losing it loses ownership and cleanup authority while VMs may remain.
Restarting only the Runtime with its store alive preserves that authority.

Submit work through `SmolBox.submit/2`; retained machines use `SmolBox.Machines`.
Wait for the worker to report ready before exercising lifecycle operations.
`SmolBox.drain_worker/2` stops new assignments. Inspect `worker_maintenance/2`,
finish or delete retained machines, then use `resume_worker/3` with the reported
control version. A retained reservation keeps maintenance blocked until deletion.

The [runnable repository example](https://github.com/hfiguera/smolbox/tree/embedded-port-design/examples/embedded_port)
uses only public lifecycle APIs. It checks disposable execution, byte-exact binary
files, commands while draining, a normal Runtime restart with its store alive,
versioned resume and final deletion. From the repository root, set the five approval
environment variables described in its README and a fresh private run directory:

```sh
export SMOLBOX_EMBEDDED_RUN_DIRECTORY=/absolute/new-run-directory
MIX_ENV=prod mix run examples/embedded_port/scripts/run.exs
```

The example saves a safe `evidence.json` and private encoded authority records.
Those records contain receipts and must remain private; they are forensic evidence,
not a durable store or an automatic restore mechanism. A failed attempt is not a
pass. Preserve its state and reconcile authentic owned records before retrying.

## Maintainer qualification

For an approved package, fixture and already enrolled domain, run the repository
proof with absolute paths:

```sh
MIX_ENV=prod mix run scripts/embedded-port-proof.exs --ordinary \
  --package /absolute/package --fixture /absolute/offline.smolmachine \
  --sha256 APPROVED_FIXTURE_SHA256 --domain-json /absolute/domain.json \
  --output /absolute/new-evidence-directory
```

This internal qualification harness is not a public application startup example.
Keep receipt-bearing evidence private. A failed attempt is not qualified: preserve
its evidence and reconcile authentic owned state before retrying. Ordinary mode
avoids deliberate helper/BEAM interruption. Historical patched-package Linux
boot/helper-loss and macOS durable boundaries passed; they do not qualify clean
packages. Live crash and independent CLI-race campaigns remain deferred at the
user's request. See the latest
repository progress record (`docs/design/embedded-port-progress.md`) for exact scope and failures.

## Upgrade and drain procedure

Quiesce the target, finish subscriptions and reconcile pending outcomes. Unknown
reservations block completion. Stop retained VMs normally, close the helper, retain
old assets, and preserve the enrolled generation and authentic receipts. Approve
the replacement manifest, inspect retained state, then activate the matching epoch.
Never reinterpret a foreign row or mint ownership from an inventory result.

Historical four-patch to five-patch package upgrades preserved data on both platforms.
The [clean-package evidence](evidence/embedded-port-unmodified-sdk-ordinary.json)
records explicit compatible clean helper replacements, retained data and owned
cleanup on both platforms. These are specific approved package pairs, not automatic
public store rebinding or patched-receipt adoption.
It does not qualify arbitrary firmware changes or rollback. Native store encoding
is selective version 16; legacy HTTP encodings remain supported. Upgrade every
reader before persisting native records. Compatibility with old HTTP records does
not make an old reader safe for native records, and helper rollback does not prove
store-codec rollback.

The workspace now builds against verified unmodified SDK source. New clean
packages require their own exact approvals; ordinary platform/consumer qualification
for the recorded clean packages is complete. Further changed bytes need new checks;
the four-patch/five-patch results above remain historical. Follow the
repository migration design (`docs/design/embedded-port-unmodified-sdk.md`) and
progress record (`docs/design/embedded-port-progress.md`). The migration keeps Port and
HTTP supported, with Rustler and Kubernetes reserved for later implementation.

For patched-to-clean migration, drain and delete owned machines through their
original approved package, preserve authority/history and enroll a fresh clean
target/domain, preferably under a fresh dedicated account. Direct adoption of
patched-package receipts is outside scope. Unknown reservations block migration;
never relabel assignments, rotate their generation or remove unresolved evidence.
The unmodified SDK requires one cooperating owner for the dedicated domain;
independent SDK/CLI writers and simultaneous Port/Rustler owners are unsupported.
Crash and destructive CLI-race validation remain deferred.

The public development flow is covered by ordinary lifecycle qualification.
The [clean public Runtime evidence](evidence/embedded-port-unmodified-sdk-ordinary.json)
records platform/toolchain identities, failures and cleanup; prior patched-package
evidence remains historical. Production crash
qualification and distribution approval still require the
deferred live fault gates, independent CLI races, exact binary/source and license
delivery review, and publisher signing/provenance. No package is published by
this implementation. The repository release gap assessment is
`native/release-review.md`.
