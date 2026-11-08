# Embedded Port helper (development)

The helper runs the shared engine through framed stdin/stdout and hosts the
`_boot-vm` entry point in the same executable. It never starts HTTP or invokes
ordinary smolvm CLI operations. The internal Elixir bridge, store integration and
observational recovery use this helper. Public development admission accepts
explicitly approved packages. Exact engine 0.1.0 clean packages have ordinary
platform/consumer qualification on Linux x86_64 and macOS arm64; the new 0.2.0
packages need their own qualification. Distribution and crash gates remain separate.

Build only against the verified source snapshot and private copied libraries:

The builder produces manifest schema 3 for engine 0.2.0 and protocol 2.0. Its exact compiled policy and source
metadata are mandatory hashed assets (`SMOLBOX-POLICY.json`, `NATIVE-SOURCE.json`);
licenses are mandatory assets too. The approved manifest digest in helper config
binds those policies and the exact SDK feature descriptor. Private helper config
schema 2 selects this protocol. Fresh creates use journal-bound material receipts;
durable assignments require selective codec v17 and reader-first store upgrade.
The Elixir bridge separately preserves approved engine 0.1.0/protocol 1.3/1.4
packages and v16 authority. Legacy approvals cannot approve rebuilt bytes or
promote receipts. Ordinary compatible upgrade proofs require matching engine,
SDK and policy; a major-protocol migration requires drain/delete and fresh authority.

```sh
python3 native/bootstrap.py
LIBKRUN_BUNDLE=/private/copied/runtime/lib cargo build \
  --manifest-path native/Cargo.toml -p smolbox-port --release --locked
python3 native/package.py --executable native/target/release/smolbox-port \
  --assets /approved/local/runtime --output /new/local/package
```

Use the optimized build for actual package checks and native proofs. The debug
build's SHA-256 asset verification is too slow for the proof startup timeout.
The package builder never downloads or publishes. It copies all libraries and
rootfs, clones only caller-provided disk templates, shrinks those owned clones
to a 1 GiB baseline, and ad-hoc signs the actual macOS executable with its
hypervisor entitlement. It records sorted file/link identities, exact source,
executable and asset digests, platform and architecture. The local package also
pins the selected installed resize2fs path/digest; general package portability,
host-tool policy, binary license/corresponding-source audit and distributable
signing remain release work. SDK license documents alone do not cover that gate.

The executable has its own relative library search path. Preflight verifies the
manifest's caller-approved SHA-256, compiled source/version, actual executable,
asset hashes/sizes/modes, complete rootfs/library inventory, required libraries,
templates/agent, host tool and (on macOS) sealed signature plus literal boolean
hypervisor entitlement. File hashes use fixed buffers; final symlinks and symlink
parents of regular assets are rejected. Rootfs links are verified without
following them. Fixed signature utilities have capped output and five-second
limits. A rejected package emits only a framed rejected Hello and a safe stderr
category; it opens no engine or VM. This is local package integrity, not remote
attestation or isolation against an actor with the same account's write access.

Start with `smolbox-port --config /absolute/config.json`. Configuration is strict,
bounded JSON, for example:

```json
{
  "schema": 1,
  "target_id": "embedded-local",
  "generation": "0123456789abcdef0123456789abcdef",
  "allow_initialize": false,
  "package_manifest_sha256": "<64 lowercase hex characters>",
  "approved_artifacts": [
    {"path": "/approved/image.smolmachine", "sha256": "<approved digest>",
     "max_bytes": 100000000, "guest_platform": "linux/arm64"}
  ]
}
```

A domain generation is operator-selected and persisted, never regenerated on
helper restart. Initialize explicitly only on first enrollment. Native paths
remain the SDK's verified account defaults, with one authority per OS account;
there is no arbitrary per-target DB isolation. Prepared creation must match an
approved catalog entry exactly. Runtime library/rootfs/template paths are set to
the verified package before engine construction, image seeds are disabled, and
boot debug/rootfs-tar overrides are removed. Every selectable account and
executable-directory template must match approved bytes and geometry; missing
account templates are installed sparsely without overwriting conflicts.
Account templates remain immutable. Creation normalizes only its newly owned
backing files to mode 0600 before receipt publication, rejecting redirected,
shared-inode or unexpectedly owned files. A read-only SDK manager resolves the
actual paths after pack seeding, including Linux qcow2 overlays; disk seeding and
geometry remain the SDK's responsibility. Clean asset-preparation policy is
version 2, so packages using the earlier policy cannot carry receipts through a
compatible-upgrade proof.

The [protocol contract](../smolbox-protocol/README.md) defines Hello/approval,
strict IDs, operations, credit and outcome evidence. A dedicated reader admits
bounded requests and directly handles approval/cancel/credit, independently of
native work and upload disk writes. Four work threads and two control threads
share at most 32 accepted operations. Control does not wait on a VM lifecycle
lock; cancel of an admitted request works before the coordinator queues it.

Uploads are chunked into owned temporary spools, collectively capped at 128 MiB.
No guest write starts before the complete declared total arrives; the engine
reads that spool through its bounded streamed-write API. Queued canceled requests
never reach native dispatch. Output uses one writer, at most 8 MiB decoded/
12 MiB encoded including envelopes, at most 4096 event frames and 65 reserved
control frames; a frame remains charged while its OS write is in progress.
Both decoded-byte credit and event-count credit can be replenished only after
consumption; at most 64 output events per request are outstanding even for tiny
chunks. Partial byte acknowledgment cannot release a whole message slot. A worker may wait up to one
second (or its remaining budget) for credit, releasing the registry lock so
control remains responsive. Exhaustion disqualifies success and cancels that
stream. Queue limits and credit are both necessary; neither proves host quotas.

Budgets start at request receipt and include queue/upload time. Independent
native deadlines and helper cancellation preserve real Exit evidence. A stuck
native call after three seconds of cancellation grace makes the entire channel
uncertain. Writer stalls have a five-second limit; an independent ten-second
watchdog handles a stuck coordinator/registry. EOF/shutdown cancel pending work,
stop only tracked owned VMMs, retain disks, and use bounded native shutdown.
Channel failure or panic never creates a fake terminal/Exit. The durable bridge
reconciles process loss observationally and preserves uncertain commands.

Protocol 1.4 also reports engine unavailability without closing the healthy
channel or interrupting retained collectors. The notice stops new public
admission, preserves pending outcomes and capacity, and cannot authorize a
restart. Native shutdown errors, including failed epoch sealing, cause a failed
helper exit rather than a successful shutdown report. These deterministic
contracts do not qualify live owner-loss behavior.

Protocol 1.3 also exposes an observational `inspect_creation` query over the
original approved creation intent. It returns only streamless `absent` or
`unverified` presence, never an adopted receipt. It checks existing SDK rows,
reservations and VM material without artifact preparation or guest startup.
Explicit deleted resolution uses it only after target/worker quiescence;
automatic recovery preserves lost-receipt reservations. Lifecycle, exec and file
operations continue requiring full receipts.

The qualification introduced in protocol 1.2 precedes VM reservation and retained-slot attachment.
The engine hashes the approved pack, verifies its footer/manifest and resource
policy, and permits explicit numeric UID[:GID] only for container packs. It may
populate an immutable digest cache; it creates no VM record, directory or handle.
Create repeats these checks. A streaming validator requires the exact sidecar
layout, all declared regular assets with their declared sizes, canonical layer
filenames, complete nested tar data and compression termination. Undeclared or
duplicate assets and outer asset file/parent collisions fail. Ext4 templates
require valid superblock geometry within the admitted backing disk; VM manifests must also
match the exact admitted logical sizes, using the full raw asset length when the
SDK omits a logical-size field. Truncated assets need explicit logical size.
This verifies structure and geometry,
not filesystem consistency or successful guest boot.

Pack validation allows at most 256 declared assets, 200,000 tar records and
128 GiB of cumulative apparent bytes across outer and nested archives. The outer
decoded stream has an independent 128 GiB cap. Paths are capped at 4096 bytes,
GNU/PAX metadata at 16 KiB, sparse maps at 4096 extents and a finite number of
extension blocks, and the zstd window at 8 MiB. Old-GNU sparse files and bounded
GNU/local PAX paths are supported. Global PAX and GNU sparse PAX formats are not
qualified. Outer asset links are rejected; guest archive links must stay in the
guest root. Validation writes no extracted files and invokes no SDK cache eviction,
mount, inventory or materialization. Query budgets use helper queue/cancellation
bounds; this does not qualify a hard deadline for a stuck kernel filesystem call.
The SDK collector's empty `layers/` and `lib/` structural directories are allowed,
including bare-VM packs with no OCI layers; they cannot replace a declared file.

Ordinary macOS arm64 proof (see the progress record) qualified create/start,
real stdout/stderr and Exit, CPU/RAM/disks, numeric user, atomic capped file I/O,
EOF with retained storage, fresh-epoch receipt recovery, deadline without Exit,
and verified owned stop/delete. It used the optimized signed helper without
DYLD_LIBRARY_PATH or runtime asset overrides. Deterministic tests launch no VM;
the explicit proof below saves intent before create and refuses output reuse:

```sh
python3 native/smolbox-port/tests/ordinary_proof.py \
  --package /approved/local/package --fixture /approved/image.smolmachine \
  --sha256 APPROVED_DIGEST --domain-json /enrolled/domain.json \
  --output /new/proof-directory
```

Those recorded proofs used historical patched packages. New clean packages need
their own ordinary platform and consumer evidence. Lifecycle checks now use
SmolBox's cooperating gate and pre/post observations around ordinary SDK APIs;
independent SDK/CLI writers remain unsupported. Live owner loss, boot faults,
persistence interruptions and destructive CLI races remain deferred. No native
package publication is authorized by these checks.

The internal Elixir Port owner now verifies the manifest and executable before
launch, approves the exact Hello, bounds writes and subscriptions, and retains
unread output charges after terminal receipt. An explicitly started embedded
supervisor isolates helper recovery. Caller/observer death requests scoped
cancellation; the caller must also monitor owner death. Every fresh channel
requires observational reconciliation and explicit activation before mutations.
These components participate in public development runtime assignment, store
enrollment and receipt-bound recovery. See the [public setup guide](../../docs/embedded-port.md)
for startup and the runnable example. Remaining live fault and distribution
qualification limits are recorded separately; public development availability
does not claim crash certification or publisher approval.

The separate ordinary Elixir proof exercises the actual OS Port owner, preserving
a real nonzero Exit and binary file data, recovering retained storage after
graceful stopped-helper replacement, and verifying owned deletion:

```sh
mix run scripts/embedded-port-proof.exs --ordinary \
  --package /approved/local/package --fixture /approved/image.smolmachine \
  --sha256 APPROVED_DIGEST --domain-json /enrolled/domain.json \
  --output /new/proof-directory
```

Both proofs use the account's native data domain, require Python 3 for readonly
inventory evidence, and save immutable private intent/receipt records before
subsequent actions. They refuse an existing output directory and never adopt
creation authority from labels or inventory. Owner-process death here is not
whole-BEAM/native-helper SIGKILL qualification or durable-store recovery.

The separate [durable runtime proof](../../docs/design/embedded-port-durable-proof.md)
uses the encrypted PostgreSQL example across fresh BEAM processes. It also
qualifies BEAM SIGKILL after committed attached-command intent and before native
send, followed by observational recovery, explicit resolution and verified
deletion. The remaining create/start/result-persistence and other fault boundaries
are separate gates.

The explicit artifact proof qualifies the real approved pack, then checks small
malformed pack fixtures against both qualification and direct creation. Valid
synthetic container/VM controls establish that rejection reaches content/geometry
checks. It verifies no stream/receipt and no native inventory change. Synthetic
VM controls are not bootable VM-pack qualification. The `zstd` executable is a
fixture-authoring dependency of this proof, not a helper runtime dependency:

```sh
python3 native/smolbox-port/tests/artifact_proof.py \
  --package /approved/local/package --fixture /approved/image.smolmachine \
  --sha256 APPROVED_DIGEST --domain-json /enrolled/domain.json \
  --zstd /absolute/path/to/zstd --output /new/artifact-proof-directory
```

The live VM-mode proof uses the SDK fixture-authoring example to make a seed from
the verified package's disk templates, creates/boots a receipt-owned bare source,
writes root/storage witnesses and stops it. The authoring tool then holds the
native account-domain and source-operation locks, verifies the saved full receipt
is stopped, and exports through the pinned SDK library. It does not add an export
capability to SmolBox. The imported VM must preserve both snapshots, apply CPU/RAM
and disk sizes, ignore the baked workload, survive stop/start and helper EOF, and
complete binary file I/O before verified deletion of both saved receipts.

```sh
LIBKRUN_BUNDLE=/private/copied/runtime/lib cargo build \
  --manifest-path native/Cargo.toml -p smolbox-engine \
  --example owned-proof --release --locked
python3 native/smolbox-port/tests/vm_pack_proof.py \
  --package /approved/local/package --domain-json /enrolled/domain.json \
  --fixture-tool /absolute/native/target/release/examples/owned-proof \
  --output /new/live-vm-proof-directory
```

Fixture authoring requires the Rust example; consumption uses the signed helper.
The proof refuses output reuse and saves private intents and full receipts before
later actions. Failure cleanup uses only returned receipts. A create without a
returned receipt remains uncertain. This is ordinary live macOS qualification;
remaining fault/platform and package-consumer gates still apply.
