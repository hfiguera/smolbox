# Embedded Port implementation plan

Status: proposed, October 10, 2026. No implementation or live qualification is
claimed by this plan. Follow the decisions in
[the design](embedded-port.md); keep the existing HTTP backend usable throughout.
The initial deliverable is the required Port feature matrix, not Rustler or a
native Kubernetes backend.

## Phase 0 — Pin the engine and resolve native integration gaps

- Record the exact smolvm revision, dependency/asset versions, licenses, and patch
  provenance. Use the reference checkout for research without editing it.
- Trace prepared local `.smolmachine` creation from HTTP through manifest
  validation, pack layers, VM-mode disks, workload defaults, and record provenance.
  Specify the minimal public shared-library entry point required by the engine.
- Establish typed observational inspection that distinguishes DB errors, absence,
  stopped, frozen/paused, and live/unreachable PID identity without booting or
  materializing storage. Specify any upstream public API changes needed.
- Audit all default-DB/cache/VM path lookups. Implement a coherent native path
  context if feasible; otherwise document and enforce one embedded domain per
  dedicated OS account. A `with_db` override alone is not sufficient.
- Establish bounded exec/file APIs, real Exit/Error/cancel normalization,
  resource validation, handle shutdown, and scoped child reaping. Document the
  upstream output cap and any required lower-level streaming integration.
- Decide the exact native package layout, offline asset resolution, and supported
  Linux/macOS architecture matrix. Verify the helper can launch `_boot-vm` with
  required libraries, rootfs, disk tools, and macOS entitlements.

Exit gate: a written dependency/API gap record and a small native proof that
creates an approved prepared image, boots it neutrally, executes, stages/reads
a file, stops, and deletes only its owned VM. Record real applied resources and
empty owned inventory. No SmolBox public feature is declared available yet.

## Phase 1 — Extract the backend boundary while retaining HTTP behavior

Primary areas: `lib/smolbox/runtime/`, `lib/smolbox/client.ex`,
`lib/smolbox/runtime/worker_config.ex`, `lib/smolbox/runtime/config.ex`,
`lib/smolbox/machine.ex`, and optional managed operation modules.

- Add `SmolBox.Backend`, typed observations, request budgets, and explicit
  capability checks. Add the HTTP implementation delegating to existing Client.
- Normalize `WorkerConfig` into internal runtime targets. Remove orchestration's
  dependency on `client.worker.id`, HTTP-specific budget struct updates, and
  HTTP readiness counters. Keep existing constructors and public Client behavior.
- Inventory every managed Client call: disposable/retained lifecycle, health,
  observations, staging/collection, cleanup, registry preparation, exports,
  checkpoints, branches, disk expansion, local volumes, and terminal connections.
  Mint/direct terminal transport paths also need capability-aware delegation.
- Route these through the backend boundary, including optional operation families.
  Leave low-level public HTTP Client use supported.
- Gate unsupported features before reservation and dispatch. Preserve current
  HTTP ownership, same-incarnation comparison, evidence, redaction, and budgets.

Exit gate: current deterministic contract/store suites and HTTP live checks pass
unchanged in meaning. Public transport implementations still work. Add focused
contract tests for capability rejection and observation semantics rather than
tests that merely mirror delegation functions.

## Phase 2 — Build the shared native engine

Proposed areas: `native/smolbox-engine/`, native workspace manifests and lockfile.

- Implement typed operations using the pinned smolvm library and Phase 0 shared
  APIs. Keep engine DTOs independent of Erlang, JSON, and Rustler.
- Implement approved pack creation, immutable artifact verification/materialization,
  neutral startup, ownership labels, lifecycle and observational identity checks.
- Implement foreground argv/env/workdir/qualified user, dedicated agent connections,
  decoded-byte output caps, ordered events, and explicit terminal evidence.
- Implement bounded guest file staging/collection with atomic writes. Avoid whole
  file accumulation via the current default multi-gigabyte read API.
- Add an operation registry, cancellation tokens, bounded native work/control
  queues, per-VM lifecycle serialization, and explicit owner-bound shutdown.
- Enforce offline-only profiles and reject unsupported resources/features rather
  than accepting fields the native constructor ignores or clamps.
- Hold the native domain lock. Include only owned VMM children in cleanup/reaping;
  retain storage until an explicit verified delete.

Exit gate: native contract tests distinguish Exit from successful function return,
cancel from termination, missing from DB failure, and foreign from owned records.
Real stop/start preserves retained files; concurrent control cannot corrupt exec
output or cancel another machine's command.

## Phase 3 — Implement the protocol and self-booting helper

Proposed areas: `native/smolbox-protocol/`, `native/smolbox-port/`, protocol fixtures.

- Freeze versioned DTOs, limits, handshake, epoch/request IDs, sequence rules,
  terminal forms, credit/cancel messages, and safe diagnostics.
- Implement four-byte framing with a maximum length check before allocation,
  strict bounded JSON/base64 validation, and a single framed-output writer.
- Implement handshake/preflight and a reader independent of blocking operations.
  Reject overload before native dispatch; reserve control capacity for cancel.
- Enforce output credit, aggregate encoded/decoded queue limits, chunking, and
  independent native time/byte budgets. Test the proposed numerical defaults;
  record changes before treating them as release limits.
- Add `_boot-vm` dispatch to the same helper executable. Set boot environment
  before engine initialization, disable shared image seeds, and keep all native
  debug/child logs off protocol stdout.
- Add bounded shutdown/EOF handling. Pending operations without sufficient
  completion evidence remain uncertain when the channel fails.

Exit gate: malformed/truncated/oversized input, bad base64, sequence/epoch errors,
slow readers, credit exhaustion, full queues, helper EOF, and concurrent streams
produce bounded behavior without false success or unintended operation dispatch.
Include a helper log test proving stderr cannot corrupt the protocol.

## Phase 4 — Add the Elixir Port bridge and embedded configuration

Proposed areas: `lib/smolbox/embedded/`, `lib/smolbox/backend/embedded.ex`,
`lib/smolbox/runtime.ex`, and target configuration/health modules.

- Add side-effect-free `Embedded.Config` validation and an `Embedded.Bridge`
  behaviour. Reserve the Rustler implementation without adding a NIF dependency.
- Start the embedded supervisor/brokers only for explicitly configured targets;
  keep starting the library application inert.
- Open the verified executable without a shell. Implement framed handshake,
  bounded Port writes/queues, request correlation, caller monitors, timers,
  sequence validation, output credits, and exactly one caller completion.
- Translate engine events into existing result/error/evidence semantics. Acceptance
  never marks `:running_observed`; output or a qualified agent acknowledgment may.
- Keep pending calls and subscriptions bounded. Observer Task death triggers
  cancel/drain handling in the broker even when the Task cannot run an `after`.
- Isolate helper restarts to their target. Mark it unavailable, classify pending
  uncertainty, back off, handshake, and reconcile before readmitting work.
- Prevent duplicate brokers/helper processes for a domain. Resolve helper health
  separately from current HTTP readiness and operator capacity declarations.

Exit gate: starting no embedded target launches no helper; mixed HTTP/Port runtimes
continue serving healthy targets during a helper crash. Killing an observer does
not cancel unrelated requests, leak subscriptions, or release unknown reservations.

## Phase 5 — Integrate durable assignments and recovery

Primary areas: `lib/smolbox/store/`, the memory adapter and PostgreSQL/Ecto example,
coordinator, sessions/executor, managed-machine orchestration, and cleanup.

- Add selective native target/domain bindings and backend-specific evidence using
  the next available codec version (the design baseline is v15). Keep legacy
  HTTP decoding and fingerprints stable; old readers fail closed on native data.
- Negotiate new store capabilities where required. Extend atomic reservation and
  retained-machine/command transactions in every supported store implementation.
- Persist dispatch intent before bridge sends. Separate bridge epoch from durable
  assignment identity; reject domain reassignment while records/reservations exist.
- Implement observational restart recovery, verified cleanup, and command-slot
  blocking after unknown exec/file/lifecycle outcomes. Never replay exec or adopt
  an unverified creation from matching inventory labels.
- Preserve reservations for stopped/unknown machines. Missing retained machines
  remain missing; startup does not recreate or boot them.
- Document coordinated controller adoption, quiescence, migration/rollback limits,
  and explicit resolution of ambiguous native mutations.

Exit gate: memory and durable-store conformance tests cover both sides of intent,
dispatch, terminal/result persistence, and cleanup. Fresh BEAM processes recover
retained assignments and unknown commands without replay or capacity duplication.
Old HTTP records remain readable and retain their existing identities.

## Phase 6 — Qualify faults and native package consumption

Build fixture executables for deterministic protocol failures and use dedicated
approved native fixtures for live tests. Confine exhaustion/adversarial work to
the disposable Linux lab according to existing qualification practice.

| Scenario | Required outcome |
| --- | --- |
| Helper killed before send/after acceptance/during exec | Correct dispatch evidence; no replay; unknown reservations retained where needed |
| BEAM killed around create/start/result persistence | Owner-bound behavior observed, storage retained, restart uses durable intent |
| Helper lost while retained VM is idle | No record/disk deletion; stopped versus live state verified before next mutation |
| Slow consumer, endless output, large files, command deadline | Queues/memory/time stay within declared budgets; no fabricated Exit |
| Caller death/cancel before attach and during exec | One operation canceled; missing Exit stays unknown; unrelated work survives |
| DB busy/corrupt/unavailable or live PID without agent | Typed failure/unknown; no conversion into disposable stopped/missing evidence |
| Foreign CLI record, copied labels, changed creation fields | No automatic adoption or destructive prefix-based cleanup |
| Same name deleted/recreated, stale PID/start time | Fail closed when incarnation cannot be proven; preserve uncertain ownership |
| Unsupported stdin/background/network/checkpoint request | Rejected before reservation/native dispatch |
| Upstream Error followed by Rust `Ok`, cancel without Exit | No successful result fabricated |
| Duplicate helper/domain, stale events after restart | No second capacity domain; stale replies cannot satisfy new calls |
| VM boot/child exit and repeated helper shutdown | Scoped reaping; no zombie accumulation or sibling child-status theft |
| Missing/wrong assets, unsigned macOS helper, debug boot env | Preflight/boot fails safely; protocol remains framed |

Run a real approved-pack execution and retained stop/start/recovery sequence on
Linux x86_64 and macOS Apple Silicon, recording exact builds and assets. Add other
platforms only after their own evidence. Verify guest applied resources, file
persistence, cleanup ownership, and inventories after tests.

Validate the same native package from a fresh consuming Elixir application on
current/minimum supported toolchains. Include a consumer with no Rust compiler
and an HTTP-only consumer with no native assets. Exercise compatible upgrades,
missing packages, domain mismatch, and coordinated codec adoption.

Exit gate: focused fault matrix, relevant full analyzers/contracts/docs/package
checks, live platform evidence, and verified fixture cleanup pass. Report any
unqualified feature/platform explicitly; do not infer production host quotas.

## Phase 7 — Document and deliver the first Port release

- Publish an embedded setup/lifecycle guide and examples for approved offline
  image executions and retained machines. Show Port selection, local package
  installation, data-domain ownership, budgets, and owner-bound VM behavior.
- Document the first-release capability matrix, helper failures, unknown result
  resolution, artifact/storage retention, prerequisites, and upgrade/draining.
- Add build/release automation for signed/digested native packages without changing
  HTTP-only installation requirements. Integrate Rust checks where native code is
  now shipped; include package manifests/licenses in distribution review.
- Record HTTP regression and embedded qualification evidence separately. Change
  release/version metadata only when implementation and qualification are ready.

Exit gate: a fresh user can follow the documented Port example from installation
through verified deletion; release notes accurately identify development scope.
Publication remains a separate action from implementing this plan.

## Subsequent deliverables

1. **Detached lifetime:** add supported handle detach and explicit parent-watch
   control, then prove survival/reconnect across graceful exit, helper/BEAM SIGKILL,
   boot-time parent loss, upgrades, and durable recovery. No implicit enablement
   from the machine's persistent flag.
2. **Optional embedded capabilities:** qualify finite stdin, workloads, networking,
   mounts/volumes, remote preparation, checkpoint/branch/export/resize, and terminal
   operations independently through the same backend contract.
3. **Rustler:** add the optional NIF crate/bridge, shared engine conformance tests,
   native worker/dirty scheduler limits, resource destruction/cancellation tests,
   and same-domain quiesced bridge switching. Port remains supported.
4. **Native Kubernetes:** design Pod namespace/UID ownership, artifact distribution,
   RuntimeClass, scheduling/capacity, exec/file observation, API failure recovery,
   and cleanup. Implement a backend rather than a Port/Rustler bridge; retain HTTP
   workers deployed in Kubernetes as a separate supported deployment model.

Phases 0–5 establish the required functionality; Phase 6 proves it and Phase 7
makes it usable. Optional future capabilities must not delay delivery by becoming
implicit first-release promises.
