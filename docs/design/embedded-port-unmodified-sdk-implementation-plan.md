# Implementation plan for an unmodified embedded SDK

Status: ordinary development implementation complete, October 12, 2026. Implements the
[unmodified SDK design](embedded-port-unmodified-sdk.md) on the existing embedded
Port backend. Keep Rustler as a future bridge to the shared engine. Crash and
destructive CLI-race qualification remain deferred; no phase below resumes them.
The [completion audit](embedded-port-unmodified-sdk-completion-audit.md) maps every
numbered item and gate to verified implementation/evidence; excluded release and
fault gates remain open.

The next proposed scope is the separate
[HTTP-parity design](embedded-port-http-parity.md) and
[implementation plan](embedded-port-http-parity-implementation-plan.md). Completion
of this migration is not HTTP feature parity; the new feature work is not enabled
or qualified by the existing evidence.

Deliver small reviewable commits. Keep current HTTP behavior and the existing
approved development packages usable until the replacement is ready. This plan
does not publish packages or implement the Rustler or Kubernetes backends.

## Phase 0 Record clean source and API boundaries

Primary areas: `native/vendor/`, `native/bootstrap.py`, `native/Cargo.toml`,
`native/Cargo.lock`, `native/tests/`, and native package/source identity tests.

1. Inventory every use of the five patched APIs and environment hooks, including
   helper preflight, engine contracts, consumer fixtures and source metadata.
2. Materialize the clean existing `9f446ae0` archive into an isolated comparison
   directory. Verify origin, tree, archive and complete file inventory. Keep the
   research checkout read-only and current approved packages unchanged.
3. Choose the ordinary dependency source: an official published crate if it
   exposes the required APIs, otherwise an exact clean upstream source snapshot.
   Do not assume the runtime's release number means every crate is published.
4. Add the clean source manifest format and verification path. The final path
   records zero applied patches and never calls `git apply`, rewrites upstream
   source, or uses Cargo `[patch]` to replace smolvm with a fork. Exact lockfile
   versions and verified offline source inputs remain supported.
5. Document public APIs used for pack preparation, agent transfers, boot dispatch,
   lifecycle and SDK record observation. Isolate unavoidable version-specific
   record/path/schema knowledge in a single compatibility module.
6. Define distinct identities for old approved patched packages and new clean
   packages. Update engine/package/config tests to reject identity substitution.
7. Complete small non-VM feasibility checks for worker-only agent access,
   template resolution and an epoch-specific boot launcher before committing to
   the full refactor. The clean SDK must carry the exact launcher/context through
   its existing API; no hidden upstream spawn hook is assumed.

Exit gate: a clean-source inventory, explicit API/compatibility map and build
strategy. Replacement development may temporarily retain the current patch path
until all call sites are removed, but no partial migration is called complete.

## Phase 1 Add shared host context and ordinary process supervision

Primary areas: `native/smolbox-engine/src/`, `native/smolbox-port/src/`,
`native/package.py`, native manifests and protocol fixtures.

1. Define transport-independent `HostContext`, epoch owner identity, executable
   locator, finite process budgets and operation identity. Keep durable receipts
   separate from live child handles and transport request IDs.
2. Add a transfer supervisor and a file-worker executable mode. Use private pipes
   and bounded messages; validate lengths before allocation. Workers receive only
   an authorized transfer request and cannot initialize SDK runtime ownership.
3. Track direct children through owned process handles and observed birth
   identities. Implement finite normal shutdown, cancellation escalation and
   per-child collection without unrelated-child sweeps.
4. Integrate four active transfer workers into the existing four work slots,
   preserve two control slots, and bound FDs, aggregate spool bytes and pending
   work. Exhausted admission must reject before guest dispatch.
5. Test correlation, framing, queue admission, normal child exit, malformed worker
   messages and cleanup with non-VM fixtures and deterministic fake process
   events. Do not run live process-loss tests to establish this exit gate.

Exit gate: the shared engine can supervise and normally collect a bounded worker
without depending on Port, Rustler terms or patched SDK APIs.

## Phase 2 Replace file cancellation and connection hooks

Primary areas: `native/smolbox-engine/src/files.rs`, `exec.rs`, worker mode,
Port streaming/credit integration, file outcome contracts and examples.

1. Move SDK connection and capped read/exact-sized atomic write calls into the
   transfer worker. Use the clean SDK's public APIs; remove patched socket cloning
   and timeout construction from the engine.
2. Keep receipt checks, machine/source leases and activation in the controller.
   A worker must connect only to an observed running agent and must not implicitly
   boot or detach a VM.
3. Carry one monotonic budget through queueing, spawn, connection, transfer and
   collection. Keep a finite host deadline even if an SDK call installs a longer
   timeout. Retain leases until the exact worker is collected.
4. Propagate byte/event credit through worker pipes and host spools. Preserve
   16-MiB transfers, 64-KiB public chunks, bounded output and one terminal per
   request. Any changed public limit requires an explicit protocol decision.
5. Separate transfer acknowledgment from process exit and request cancellation.
   Retain uncertainty after a potentially committed write with no acknowledgment;
   do not replay. Remove only authenticated owned host staging files.
6. Cover exact/short/overlong input, invalid path, capped read, fragmented output,
   modeled deadline/cancel, late acknowledgment, sibling isolation and worker
   quiescence in deterministic contracts. Ordinary live file checks use normal
   completion and shutdown; signal/fault campaigns stay deferred.

Exit gate: bounded file behavior no longer uses patch 0001 and the existing
outcome/credit semantics remain truthful. No claim of guest command termination
or rollback is introduced by worker cancellation.

## Phase 3 Make asset preparation explicit in SmolBox

Primary areas: native artifact/disk preparation, helper package preflight,
`native/package.py`, source/package metadata, setup docs and domain configuration.

1. Audit all implicit template resolutions for the clean source, including plain
   versus compressed candidates and container versus bare-VM disk preparation.
2. Use explicit approved pack assets and public disk seeding APIs wherever
   available. For remaining implicit paths, prepare approved sparse plain
   templates in the dedicated account's SDK template location before activation.
3. Verify all selectable home/executable templates against approved digests and
   geometry. Refuse conflicts, symlinks and fallback to tools/downloads; never
   overwrite unrelated account assets or change HOME/data-domain paths.
4. Remove `SMOLVM_TEMPLATE_DIR` and patched-resolver tests. Replace them with
   resolution-order, conflicting-home, compressed/plain, missing-asset and sparse
   geometry contracts against the unmodified resolver.
5. Add account template ownership/reference metadata and normal restart checks.
   Keep approved package identities stable only for unchanged bytes; account
   materialization is separately recorded and cannot authenticate a publisher.

Exit gate: every supported creation/boot path selects approved assets without
patch 0002. Existing account/domain bindings remain coherent.

## Phase 4 Centralize lifecycle and recovery observation

Primary areas: `native/smolbox-engine/src/machine.rs`, `domain.rs`, `identity.rs`,
the compatibility observation module, Runtime native resolution and store tests.

1. Establish one machine gate for all cooperating lifecycle and I/O activation
   paths. Keep account/domain ownership shared across bridges; reject duplicate
   owners and forbid direct bridge-to-SDK bypasses.
2. Replace checked SDK callbacks with precondition checks under that gate and
   ordinary SDK start/stop/delete calls. Preserve full receipt/material/marker,
   dependent-clone, PID/birth and post-operation observation checks.
   Establish lock ordering: retain SDK source leases for I/O, but never hold an
   outer copy of a source flock while calling a lifecycle method that takes it
   internally. Cover self-contention without launching a VM.
3. Classify failed preconditions as not dispatched and failures after SDK entry
   conservatively as uncertain. Remove assertions claiming protection against
   independent writers during the SDK mutation interval.
4. Implement the separate read-only SQLite observation adapter for VM rows and
   creation reservations. Bind it to supported schema/source identity, open only
   an existing DB, never write/migrate/reap, and check device/inode/path identity.
5. Require epoch fencing, creator/worker quiescence, domain ownership, the machine
   gate, a consistent DB observation and complete material/handle absence before
   returning `Absent`. Preserve stale reservations and partial/foreign material.
6. Keep unknown/unsupported schema, corruption, missing/replaced DB, redirection,
   contention and unresolved child state from releasing capacity. Ensure the
   Runtime and PostgreSQL adapter retain unknown reservations on every such result.
7. Use deterministic in-memory and temporary-DB contracts for both bridges' engine
   entry points, no replay, observational absence and the narrowed exclusivity
   contract. Do not run destructive concurrent CLI writers or live durable crash
   boundaries. Keep old codec readers and HTTP fingerprints unchanged.

Exit gate: patches 0003 and 0004 have no call sites. Verified absence is enabled
only if the clean-source adapter proves its supported contract; otherwise report
the capability limitation explicitly and retain unknown reservations.

## Phase 5 Guard boot in SmolBox and preserve Rustler boundaries

Primary areas: shared host/owner context, helper `_boot-vm` dispatch, package
layout, launcher configuration and non-VM guard contracts.

1. Prototype an epoch-specific approved launcher executable and immutable owner
   context using the clean SDK's existing boot-binary setting. Establish how the
   launcher's invoked path resolves its context without trusting arbitrary argv
   paths. Record expected owner PID/birth before spawning.
2. Verify executable/context permissions and identities, SDK config path mapping,
   old-versus-new epoch separation, macOS signature preservation, and library
   search paths. If this transport cannot carry safe owner context, report the
   exact API constraint before proceeding; do not use a mutable global owner file.
3. Implement the synchronous parent check and finite owner watcher before calling
   the unmodified SDK boot routine. Refuse invalid context, owner mismatch and
   watcher initialization failure; never use initial child `getppid()` as authority.
4. Verify compatibility with SDK descriptor closure and syscall filtering through
   source review and deterministic contracts. Treat the SDK's watchdog as
   redundant rather than sufficient for SmolBox ownership.
5. Ensure the guard and transfer supervisor take a generic host identity. For a
   future direct Rustler engine that identity is BEAM; no NIF-specific policy is
   added to the SDK layer.
6. Document Rustler activation gates: no mutation of BEAM environment, safe public
   bundle/seed/path configuration, bounded native scheduling, asynchronous resource
   destruction and no overlapping domain owner. Port may use a controlled child
   environment before worker threads; a NIF cannot inherit that assumption.

Exit gate: patch 0005 is replaced in SmolBox source and ordinary boot uses the new
launcher. Live pre-main owner loss, watcher failure injection and abrupt shutdown
qualification remain deferred and are recorded as such.

## Phase 6 Remove patches and deliver clean development packages

Primary areas: `native/upstream-patches/`, `native/vendor/`, bootstrap/source tests,
Cargo lockfile, native builder, Elixir package identity/handshake, guides/examples.

1. Switch the normal build to the verified unmodified source. Remove the five
   active patch files, application logic, patched API references and stale comments.
   Historical milestone evidence remains in Git and documentation; do not rewrite
   old results to describe clean packages. Replace active documentation links to
   removed patch files with links to the recorded historical commit as needed.
2. Verify the complete materialized SDK inventory against clean upstream source.
   Add a CI source check that fails on any downstream source rewrite or patch
   configuration. Do not count an empty patch list alone as proof of clean bytes.
3. Record new helper/engine/build/source/asset identities, SmolBox worker and guard
   provenance, observation schema version and exclusive-domain contract. Update
   Hello/config negotiation together if new metadata cannot fit existing schemas.
4. Preserve v16 decoding and legacy HTTP compatibility. Reject new packages using
   old manifest approvals or assignments; no automatic receipt/package relabeling.
5. Rebuild Linux x86_64 and macOS arm64 packages. Verify normal signing/entitlements
   and asset integrity. Distribution signing/source delivery remain separate.
6. Update public setup, launch examples, package-consumer defaults and maintainer
   scripts so none resumes deferred crash/CLI-race campaigns implicitly. Ordinary
   mode must be selected explicitly for any native consumer validation.

Exit gate: a clean checkout can build the development helper with no modified SDK
source, no upstream patch application and no dependency on the research checkout.

## Phase 7 Run ordinary regression and document migration

1. Run deterministic Rust engine/protocol/source contracts, Elixir/store contracts,
   relevant analyzers and documentation checks appropriate to changed code.
2. In approved dedicated domains, run normal create, resource witness, argv/user/
   environment/workdir/Exit, bounded binary files, retained stop/start, draining,
   graceful stopped-helper replacement and authenticated deletion. Record exact
   clean package identities and restore the owned baseline inventory.
3. Run fresh public consumers on current and minimum supported toolchains without
   Rust, plus an HTTP-only consumer without native assets. Run relevant ordinary
   HTTP regressions if shared runtime/codec code changed.
4. Exercise normal durable Runtime replacement with a surviving store. Model
   unknown dispatch/result and schema-failure recovery in deterministic contracts;
   do not terminate a live BEAM or helper to populate those cases.
5. Default production migration to draining/deleting through the old approved
   package and enrolling a fresh clean target/domain. Keep old assignments and
   historical records readable. Unknown reservations block migration rather than
   authorizing a generation reset or destructive cleanup.
6. Document supported development availability, narrower independent-writer
   protection, transfer process overhead, verified-absence capability and every
   deferred fault gate. Preserve the unresolved historical Linux verification
   failure; it is not resolved by switching SDK sources.

Exit gate: ordinary development feature parity and clean-source delivery are
documented with truthful evidence. No forced helper/BEAM exits, pre-main pauses,
watcher failure injection, live durable interruption or destructive CLI races
have been run as part of this migration.

## Completion criteria

- All native SDK source matches verified unmodified upstream inputs, with zero
  active downstream patches or dependency-source rewrites.
- The embedded Port backend remains public and usable for its declared ordinary
  feature surface; HTTP behavior and installation remain compatible.
- Worker cancellation cannot be confused with guest acknowledgment or rollback;
  uncertain outcomes retain reservations and are not replayed.
- Lifecycle ownership, approved assets, observation and boot policy live in
  SmolBox, with exclusive-domain limits stated rather than hidden.
- Rustler can reuse the engine and its executables without a second ownership
  implementation; it remains disabled until its clean SDK initialization gates
  are met. No NIF implementation is required by this plan.
- New native packages have new approved identities and ordinary consumer evidence.
  Historical patched-package records and approvals are preserved without adoption.
- Crash/CLI-race validation remains deferred. Distribution approval and Kubernetes
  implementation remain outside this work.

