# Changelog

## Unreleased

- Add managed disk expansion for idle stopped/created ordinary machines on smolvm
  1.20.2, with absolute storage/overlay targets, atomic capacity and drain gates,
  immutable creation evidence, verified current allocations and explicit recovery
  after uncertain outcomes. Commands and export resource floors use grown disks.
  Add the client API and a two-process PostgreSQL/Linux walkthrough.
  Requires `managed_disk_expansion: 1` and coordinated codec v14 readers/writers;
  no additional SQL migration. Checkpoint and branch machines remain unsupported.
  See [disk expansion](docs/disk-expansion.md).

- Persist worker drain/resume control across controllers with atomic admission
  gates and versioned resume. Add bounded maintenance reports without automatic
  shutdown, stopping or deletion. Requires the optional `worker_control: 1` store
  capability; unsupported adapters no longer silently drain only one controller.
  The PostgreSQL example requires the new worker-control migration and coordinated
  writer upgrade. No machine/execution codec change is added. See
  [durable draining](docs/worker-draining.md) for upgrade and rollback constraints.

- Add typed machine measurements and worker capacity observations, bounded raw
  Prometheus reads, and ownership-checked managed measurements. Worker reports
  distinguish observed usage from durable reservations; advisory admission reports
  explain status, unsupported specifications and resource shortages. No change to
  admission, retention, drain behavior, store callbacks or durable schema.

## 0.3.1

**Worker default change:** omitted runtime versions now select smolvm **1.20.2**.
Keep existing 1.19.0 workers explicitly configured and preserve checkpoint capture
pins. No SQL migration or codec revision is added, but shared readers must be
upgraded before writing receipts containing the new runtime version. See
[Upgrading to 0.3.1](docs/upgrading-to-0.3.1.md).

- Qualify official smolvm 1.20.2 and select it by default on Linux x86_64 and
  macOS Apple Silicon. Explicit 1.19.0 and earlier supported versions remain.
  See [qualification and upgrade boundaries](docs/runtime-1.20.2-qualification.md).
  No SQL migration or codec revision is added; coordinate readers before storing
  results with the new runtime version and preserve existing checkpoint pins.
- Accept `.checkpoint` alongside `.smolcheckpoint` and record the actual worker
  version in managed export results. Managed capture filenames stay unchanged.

- Require Mint 1.11 or later and update the example locks to address
  CVE-2026-91043, CVE-2026-92103 and CVE-2026-94194. No data migration is required.
- Update the community workspace's test-only `lazy_html` dependency to 0.1.13
  to address CVE-2026-92106.

- Add a separate community workspace walkthrough for SmolBox 0.3.0 saved state,
  including checkpoint capture, branch comparison and verified cleanup. Keep its
  published dependency lock and preserve the original tutorial through its archive.
- Add an exports/checkpoints/branches comparison guide with interactive examples
  and clarify checkpoint file deletion versus reservation release in the app.

## 0.3.0

SmolBox now manages reusable machine state: approved registry sources, stopped
machine exports, checkpoint capture and independent restore, and live branches.
The default worker remains smolvm **1.19.0**.

**Coordinated upgrade required before enabling these features:** new records
selectively use codec v10–v13 and require new store capabilities. The PostgreSQL
example needs no additional SQL migration, but all shared readers, controllers
and resource projection writers must understand the new records. Deleting a
machine does not remove its durable history or make older readers compatible.
See [Upgrading to 0.3.0](docs/upgrading-to-0.3.0.md).

- Add a reproducible physical Linux comparison of fresh provisioning, exports,
  checkpoints, branches and machine reuse, with raw evidence, verified results,
  preparation costs and cleanup accounting. Measurements describe one small
  workload with warm caches, not a universal performance ranking.
- Improve fixture readiness and deterministic recovery/store test synchronization.
  Add a practical article about terminal disconnects and uncertain command outcomes.

- Add managed leaf branches from idle, offline bare sources on smolvm 1.19.0,
  including explicit held release, durable lineage and no replay after uncertainty.
- Serialize source/child admission and retain backing allowances after child
  deletion until source deletion and explicit host-confirmed cleanup.
- Add selective codec v13 and `managed_branches: 1`, with atomic memory and
  PostgreSQL storage. Upgrade shared readers and projection writers before use;
  no SQL migration is required.
- Add a durable branch example and Linux RAM/disk isolation and cleanup evidence.

- Add managed idle, offline checkpoint capture and explicit independent restore
  on smolvm 1.19.0 bare guests. Opt-in startup, bounded streaming, durable identity,
  no replay after uncertainty, and source ownership/exclusion are explicit.
- Preserve checkpoint artifact disk accounting after source deletion until explicit
  release. Capture completion requires host quiescence confirmation; capture does
  not imply in-place rollback, automatic artifact deletion or container support.
- Add selective codec v12 and `managed_checkpoints: 1`. Upgrade all shared readers
  and resource projection writers before opting in; no SQL migration is required.
- Add a durable capture/restore example and Linux disk/RAM preservation evidence.

- Add managed stopped-machine export to explicitly approved registry destinations,
  typed publication identities, durable intent and recovery without unsafe replay.
- Keep source ownership, conflicting operations, and helper capacity reserved through
  uncertain export outcomes. Verified publication requires separate operator
  quiescence confirmation before releasing helper resources.
- Add codec v11 and `managed_exports: 1`, with permanent publication tag claims and
  export history retained after machine deletion. The PostgreSQL example needs no
  SQL migration, but shared readers and resource projection writers must be upgraded.
- Add a durable export/reuse example with explicit source approval. Exported
  container state excludes `/workspace`; no memory snapshot or live branch is implied.

- Add immutable local, registry-artifact and OCI source types with exact worker
  approvals, explicit networking and host-owned registry credential resolution.
- Persist registry preparation and serialize host-cache creation work across
  controllers. Preserve uncertainty without replay or adoption by machine name.
- Add typed machine-local image inventories and managed OCI image pulls sharing
  the active-operation slot. Reject pulls on prepared-artifact machines, where
  upstream cannot provide verified download evidence.
- Add codec v10 and `registry_sources: 1` / `managed_images: 1` store capabilities.
  Existing local/checkpoint formats remain compatible; the PostgreSQL example
  needs no additional SQL migration. Upgrade all shared-store readers before
  enabling these capabilities; older releases cannot read v10 records.
- Add a durable registry/OCI example and Linux/macOS qualification evidence.

## 0.2.1

**Worker default change:** SmolBox now expects smolvm **1.19.0** when the worker
version is omitted. If your worker still runs 1.17.0, explicitly configure
`runtime_version: "1.17.0"` before upgrading SmolBox, or upgrade the worker
separately. No SmolBox store schema, codec or SQL migration is introduced when
upgrading from 0.2.0. See [Upgrading to 0.2.1](docs/upgrading-to-0.2.1.md).

- Add a Phoenix LiveView community workspace example demonstrating persistent
  machines, commands, terminals, files, background services and durable recovery.
  It retains its published 0.2.0 dependency lock and explicit smolvm 1.17.0 pin.
- Run isolated contract test modules concurrently and fix lifecycle/deadline test
  races. These improve test execution and reliability, not application throughput.
- Clarify disposable and retained machine responsibilities and deployment limits.
  Add practical articles about persistent workspaces and application readiness.
- Update the development/test dependency ex_slop to 0.4.5.

- Qualify smolvm 1.19.0 on Linux x86_64 and macOS Apple Silicon and make it the
  default. Retain explicit 1.17.0 and earlier supported workers. Expand
  runtime gates, wire/schema fixtures and recovery coverage without adding new
  upstream features or changing store schemas. Worker installation is separate;
  pin existing workers and checkpoint approvals to their actual runtime. See the
  [qualification report](docs/runtime-1.19.0-qualification.md) for evidence and limits.

- Decouple stored execution classification from runtime admission, and keep
  terminal session lookup inside the runtime. Public APIs, consumer ownership,
  stored record formats and recovery behavior remain unchanged.

- Specify every managed-machine store operation's argument layout, result type,
  transaction requirements and recovery semantics. Existing `machine/3` adapters
  remain compatible; no record format or database migration changes.

## 0.2.0

SmolBox now supports retained, interactive development environments alongside
disposable execution. This release adds persistent machines, mapped services,
long-running and background commands, interactive terminals, startup workloads
and configurable guest file policies. smolvm 1.17.0 becomes the default.

**Coordinated upgrade required:** upgrade every shared controller, reader and
store adapter before enabling new features. The PostgreSQL example adds machine
and port-ownership migrations; feature records use schemas v5–v9. Worker binaries
are upgraded separately, and existing checkpoint approvals stay pinned to their
capture version. See [Upgrading to 0.2.0](docs/upgrading-to-0.2.0.md), including
rollback restrictions and retained resource accounting.

- Add explicit `GuestPaths` upload/download/workdir roots, preserving `/workspace`
  defaults. Image workers on smolvm 1.17.0 support buffered files up to 16 MiB and
  manifests up to 64 MiB per direction with coordinated host-approved budgets.
- Persist expanded file policy in selective codec v9, require `guest_files: 1`,
  and recheck worker approval before staging/collection. Older records and
  fingerprints remain compatible; shared readers/adapters require a coordinated
  upgrade before v9 writes. No SQL migration.
- Add a configurable directory artifact limit, durable file recovery example,
  boundary tests and real-worker qualification; see [the guide](docs/guest-files.md).

- Add optional immutable startup `Workload` configuration on smolvm 1.17.0 image
  machines, preserving neutral startup when omitted and rejecting automatic restarts.
- Add bounded SSE console snapshots/follow through `Client.logs/3` and
  ownership-checked `Machines.logs/3`, with typed `LogResult`. Upstream discards
  application stdout/stderr; console diagnostics do not prove application readiness.
- Workload machines selectively use codec v8 and `managed_workloads: 1` store
  capability. Upgrade controllers/readers/adapters together; no new SQL migration.
  Add a durable startup/recovery example and workload guide.

- Add interactive WebSocket PTY sessions on managed image machines and the low-level
  client, with byte-preserving output, input, resize, typed exit evidence, bounded
  flow control and conservative disconnect recovery.
- Add selective codec v7 and `interactive_terminal: 1` store capability, preserving
  older fingerprints and wire shapes. Upgrade shared controllers/readers/adapters
  together; see `docs/interactive-terminals.md`.
- Add Mint/MintWebSocket dependencies, durable terminal examples and Linux lab
  qualification with disk-preserving worker restart.
- Prevent older machine observations from overwriting a newer lifecycle request
  or active-command assignment during reconciliation.

- Add explicit foreground command timeouts up to 24 hours, with independently
  approved observation budgets and quiet extended buffered/streaming requests.
- Add background launch on managed image machines, typed `LaunchResult` PID
  evidence, terminal `:launched` state, durable deduplication and conservative
  unknown-launch recovery. Confirmed launch releases the command slot while
  retaining the machine and its resources. No process supervision is implied.
- Extended records use codec v6 and require store capability `extended_execution: 1`.
  Ordinary foreground wire formats and fingerprints remain stable. Upgrade all
  controllers/readers/adapters together; see `docs/long-running-exec.md`.


- Add fixed TCP `PortMapping` values to low-level and managed machine creation
  on smolvm 1.17.0, with canonical identity, strict observations, independent
  outbound allowlists, and durable worker-scoped port ownership.
- Retain port reservations across commands, controller restart and stop/start;
  block conflicts and uncertain operations without remapping or replaying.
- Managed records now write codec v5; v4 loads with empty port defaults. Apply
  the PostgreSQL port-ownership migration and upgrade all controllers together,
  including deployments without mappings. See [upgrade details](docs/port-mappings.md#persistence-and-upgrades).
- Add a PostgreSQL HTTP-service example covering controller restart, stop/start,
  readiness, file persistence, explicit deletion and reservation release.

- Default to smolvm 1.17.0 on Linux x86_64 and macOS Apple Silicon after
  execution, recovery, checkpoint, network and persistent-machine qualification.
  Retain explicit 1.16.1 and earlier supported workers. Install worker binaries
  separately; keep old checkpoint approvals pinned to their capture version.
  See [compatibility evidence](docs/compatibility.md#smolvm-1-17-0-qualification).

- Add `SmolBox.Machines`, `ManagedMachineSpec`, and durable `ManagedMachine`
  records, with explicit retention, versioned lifecycle requests, sequential
  commands, blocked uncertainty, and operator resolution.
- Keep retained-machine reservations independent of commands, sharing worker
  capacity with disposable executions. Stopped machines retain full reservations.
- Add optional store transactions, codec v5 managed records with v4 read
  compatibility, and PostgreSQL machine/port ownership migrations. Upgrade every
  controller sharing workers and storage before enabling the feature; see
  `docs/persistent-machines.md`.
- Preserve disposable execution APIs and their v2/v3 serialized record shape.
- Add shared memory/PostgreSQL concurrency tests and a two-process persistent-file
  demonstration. See `docs/persistent-machines-validation.md` for evidence.

## 0.1.5 — September 18, 2026

**Checkpoint upgrade notice:** upgrade every controller sharing a store before
submitting checkpoint executions. Their schema-v3 records cannot be read by
older controllers, even after the executions finish. Image executions continue
to write schema v2 with unchanged fingerprints. No SQL table migration or worker
default change is introduced; smolvm 1.16.1 remains the default and is required
for checkpoints. See [Upgrading to 0.1.5](docs/recovery.md#upgrading-to-0-1-5).

- Add operator-approved idle, offline checkpoint sources on smolvm 1.16.1, using
  the existing HTTP client and managed lifecycle. Image execution is unchanged.
- Checkpoint records use schema v3; upgrade all controllers sharing a store before
  submitting checkpoints. Image records retain schema v2 and existing fingerprints.
- Checkpoints preserve captured processes and state. Arbitrary resumed workloads,
  networked checkpoints, capture, live branching and pools remain outside this API.
- Extend the durable host example with independent checkpoint restores and
  PostgreSQL recovery across fresh application processes, including interruption
  before and after result persistence. Document the v3 controller upgrade boundary.
- Add reproducible checkpoint benchmarks separating restore, startup, preparation,
  execution and cleanup. Record Linux cache comparisons and a precomputed-image
  baseline; nested-lab speedups are not universal or native-host performance claims.

## 0.1.4 — September 18, 2026

**Worker upgrade notice:** 0.1.4 expects smolvm 1.16.1 by default.
Upgrade the separately installed worker using the drain and verification
procedure, or configure `runtime_version: "1.16.0"` before updating the library
to retain that worker. There is no automatic fallback or additional record
schema migration. Version 0.1.3 defaults to 1.16.0. See
[Upgrading to 0.1.4](docs/recovery.md#upgrading-to-0-1-4).

- Separate managed disposal from graceful preservation. Finished executions and
  unknown executions past retention can delete their verified owned VM without
  a preliminary stop. Unknown work during retention still requires graceful
  stop and keeps its disks on failure. Identity checks, finite mutation budgets,
  observed absence and reservation accounting remain required.

- Default to smolvm 1.16.1 on Linux x86_64 and macOS Apple Silicon, including
  controlled networking. Explicit 1.16.0 support remains;
  there are no public API or record format changes. Qualification includes the
  disposal/preservation distinction above: graceful stop can still fail under
  storage exhaustion, leaving unknown work retained for operator resolution.
- Add exact candidate distribution pins, captured wire/schema fixtures and a
  reproducible comparison of 1.16.0 and 1.16.1 stop behavior under disk exhaustion.

## 0.1.3 — September 14, 2026

**Upgrade notice:** this version changes the durable record format and the default
worker version. Although numbered 0.1.3, it requires a coordinated upgrade for
controllers sharing a durable store; it is not a transparent rolling upgrade
from 0.1.2.

- Every `SmolBox.Store.Codec` write uses schema v2, including offline executions.
  New readers accept legacy v1 records; 0.1.2 readers cannot read v2.
- Stop all old controllers before starting new writers against the same store.
  After v2 writes, reverting the dependency to 0.1.2 is not a supported rollback.
- The default worker version changes from 1.14.6 to 1.16.0. Upgrade the separately
  installed worker or explicitly retain `runtime_version: "1.14.6"` (or `"1.14.1"`).
  Network policies require 1.16.0.

Follow [Upgrading to 0.1.3](docs/recovery.md#upgrading-to-0-1-3) before deployment.

### Changes

- Add explicit outbound hostname/CIDR policies for smolvm 1.16.0 while retaining
  offline defaults, profile approval and strict machine policy observations.
- Extend network validation with Linux IPv6/UDP, DNS and synthetic boundary
  checks, plus bounded macOS networking checks. Document upstream's strict
  egress floor and authenticated guest gateway exception.
- Write durable record schema v2; read exact legacy v1 offline records without
  changing their execution fingerprints. Coordinate controller upgrades before
  writing v2 records. See the controlled network access guide.

- Default to smolvm **1.16.0** on Linux x86_64 and macOS Apple Silicon after
  platform qualification, retaining explicit 1.14.1 and 1.14.6 support. Applications
  using an older worker must retain its explicit `runtime_version` or upgrade the
  worker before adopting this default.
- Record the tagged API and packaging review, actual host resizing prerequisites,
  platform runtime/recovery results and repeated constrained Linux experiments.
  The recorded runtime qualification covers real runtime and durable recovery on both platforms,
  the complete quality/language matrix and package consumers. The existing
  public five-minute command limit remains unchanged.
- Correct the lab's account-specific cleanup observations, retain private bounded
  service-fixture diagnostics, and require a live VMM near the real worker deadline.
  Earlier failed or insufficient observations remain in the qualification record.

## 0.1.2

- Default to smolvm **1.14.6** for Linux x86_64 and
  macOS Apple Silicon workers.
  **Upgrade configuration:** applications with an existing 1.14.1 worker must
  explicitly set `runtime_version: "1.14.1"` or upgrade their worker before
  using the new default. Exact version checks reject mismatches; the library
  does not install smolvm. Explicit 1.14.1 support remains available.
  Linux ARM64 1.14.6 is not qualified.
- Document the host `resize2fs` prerequisite for 1.14.6 disk requests below
  template sizes, including the observed macOS file loss after restart when
  that tool was absent. Bounded macOS compatibility checks do not qualify
  exhaustion, adversarial isolation or hard host resource limits.
- Fix the getting-started example to omit the optional Unix socket setting
  when connecting over TCP. Passing `nil` was rejected by option validation.
- Update maintainer checks and host examples to default to 1.14.6 and retain
  explicit version selection.
  Public execution APIs, persisted record formats and production dependencies
  remain unchanged. No new hard resource or isolation controls are exposed.

Native runtime and constrained Linux deployment preparation results are documented in
the compatibility guide. Exact-commit release acceptance is recorded separately.

## 0.1.1

Documentation and validation release. Library source, public APIs, persisted record
formats and production dependencies are unchanged from 0.1.0.

- Update the README and operating guides with the division of responsibilities
  between SmolBox, smolvm and the deployment, and link the recorded Linux results.
- Include evidence of external resource enforcement and failure recovery in one
  constrained Linux deployment. These results do not add portable hard-control
  options or establish the same guarantees for other deployments.
- Add repository-only tools for a disposable nested KVM lab and bounded Linux
  qualification, including separate worker data and control storage.
- Allow the supplied host examples to use a configured smolvm Unix socket.
- Add the engineering blog and strengthen runtime fixtures and CI checks.

Release validation runs on Linux. The earlier macOS results remain historical
evidence for the unchanged library; this patch does not claim a new macOS run.

## 0.1.0

First release of the development-qualified smolvm client and supervised execution
runtime. Promotes RC2's API and behavior; public APIs and persisted record formats
are unchanged. Production resource/isolation certification remains outside this
release's scope, and unsupported hard controls remain rejected.

- Publish installation through Hex and versioned API documentation through HexDocs.
- Provide typed smolvm 1.14.1 client operations and explicitly supervised execution
  with immutable identities, duplicate/conflict handling, bounded files/output,
  cancellation, recovery and cleanup. Uncertain accepted commands are never replayed.
- Include managed-execution and troubleshooting guides, PostgreSQL and minimal
  host examples, telemetry, and documented upstream and deployment limitations.
- Support the tested Linux x86_64/KVM and macOS Apple Silicon worker platforms,
  with Elixir 1.18/OTP 27, Elixir 1.19–1.20/OTP 28 and Elixir 1.20/OTP 29 lanes.
- Retain the analyzer, coverage, dependency-cycle, documentation-link and package
  consumer gates. Exact-release validation and publication are recorded separately
  in the repository's release reports.

## 0.1.0-rc.2

Second candidate for the development-qualified client/controller release.
This candidate retains RC1's execution and isolation limits and is not published
to Hex. Public APIs and persisted record formats remain compatible with RC1.

- Rewrite the README around concrete use cases and a verified Python execution
  example, with explicit setup requirements and links to the full walkthrough.
- Record successful Elixir 1.20.4 / OTP 29.0.6 development validation on both
  Linux x86_64 and macOS Apple Silicon, including real workers and durable recovery.
- Update installation, example versions and documentation source links to
  `v0.1.0-rc.2`. Exact-candidate acceptance is recorded separately in the repository's
  release-candidate reports.
- Wait for the intended process in the executable-identity regression test,
  replacing a fixed startup delay that raced on a GitHub compatibility runner.

- Align main CI and optional live-workflow checks with the pinned Elixir 1.20.4 /
  OTP 29.0.6 toolchain. Retain Elixir 1.18/OTP 27 and Elixir 1.19–1.20/OTP 28
  compatibility jobs with separate build/PLT caches for OTP 29.
- Add a complete managed-execution walkthrough, troubleshooting guide, tested
  constructor examples and public API option references. Make the README the
  ExDoc entry point and group the guides and APIs by use.
- Include linked evidence assets in the generated documentation and reject
  broken local file/fragment links in CI. Package both new user guides; keep
  developer-only Mix tasks out of the public API navigation.
- Remove dependency cycles in execution validation, the CI command runner and
  the durable host example. Public APIs and persisted record formats are unchanged;
  machine identity and execution writes remain in the same store transaction.
- Reject static file-dependency cycles in ordinary CI, with failing/passing canaries
  and a PostgreSQL regression for rollback after an execution write fails.

## 0.1.0-rc.1

Unreleased candidate for the first client/controller release. It uses the existing
development-qualified worker contract. Production resource/isolation certification,
protected real-worker GitHub infrastructure and independent consumer review are
outside this release's scope. No production isolation profile is certified.

### Implemented

- Typed client for pinned smolvm 1.14.1 health/readiness, machine lifecycle,
  argument-vector commands, bounded buffered/SSE output and binary file transfer.
  Local loopback/Unix-socket policy and authenticated, verified TLS remote access
  are explicit. Mutations have no hidden retry or redirect behavior.
- Explicitly supervised asynchronous runtime with immutable execution identities,
  duplicate/conflict handling, atomic admission, configured worker pools,
  health/readiness observations and draining.
- Persisted dispatch intent, ownership-aware recovery, cancellation, output
  collection and bounded cleanup. Lost execution evidence remains unknown;
  observation loss never authorizes command replay. Outcome, termination and
  cleanup remain separately observable.
- Versioned store and artifact-store contracts, a bounded ephemeral Memory store,
  and host-owned PostgreSQL and directory-adapter examples. The library has no
  database, workflow or language-specific runner dependency.
- Bounded, redacted asynchronous telemetry and worker/execution inspection.
  Slow handlers and dispatcher restart are isolated from execution supervision.
  Notifications are lossy; persisted execution evidence is authoritative.
- Deterministic and real Linux/macOS suites, durable controller/process-fault
  tests, standalone host examples, production-package consumer checks and CI
  gates for Dialyzer, Credo, ex_dna, ex_slop and Credence. Deliberate bad/clean
  canaries verify the analyzers and coverage gate actually run and fail correctly.
- Elixir maintainer tools for bounded commands, preflight, package consumers and
  worker-service faults. Regular CI and optional manual runtime qualification
  have separate strict result gates. Source links target `v0.1.0-rc.1`.

### Required configuration and limitations

Workers require an operator-verified `allocation_floor` covering runtime/artifact
disk templates and VMM overhead. Profiles below it fail acceptance and recovered
prepared dispatch. smolvm 1.14.1 may retain 20/10 GiB templates while reporting a
smaller request; examples use profile revision v2 with those disk sizes and
768 MiB host overhead. Existing saved specs are never rewritten. Inspect their
original identities instead of resubmitting changed specs under the same key.

Reservations do not certify host resource quotas. A bounded Linux disk-full
experiment could stop its guest but could not commit deletion because the worker
database shared the exhausted storage. Retain capacity until verified cleanup or
an explicitly evidenced operator recovery. Canonical workspace containment is
also unsupported: packed-image reads can follow guest symlinks beyond the
lexical workspace. No host path is extracted from guest archives.

smolvm provides no verified durable exec receipt or deduplication fence. An
original delayed request can start a VM after a successful stop; cleanup retains
uncertain evidence and reservations through the configured deadline/retention
policy. Stronger guarantees and unsupported hard controls are rejected or
explicitly excluded. See the compatibility, recovery and security guides for
measured behavior and unqualified boundaries.
