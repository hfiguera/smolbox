# Changelog

## 0.1.2 (unreleased)

- Default to SmolVM **1.14.6** for Linux x86_64 and
  macOS Apple Silicon workers.
  **Upgrade configuration:** applications with an existing 1.14.1 worker must
  explicitly set `runtime_version: "1.14.1"` or upgrade their worker before
  using the new default. Exact version checks reject mismatches; the library
  does not install SmolVM. Explicit 1.14.1 support remains available.
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
No 0.1.2 tag, Hex package or GitHub Release has been created.

## 0.1.1

Documentation and validation release. Library source, public APIs, persisted record
formats and production dependencies are unchanged from 0.1.0.

- Update the README and operating guides with the division of responsibilities
  between SmolBox, SmolVM and the deployment, and link the recorded Linux results.
- Include evidence of external resource enforcement and failure recovery in one
  constrained Linux deployment. These results do not add portable hard-control
  options or establish the same guarantees for other deployments.
- Add repository-only tools for a disposable nested KVM lab and bounded Linux
  qualification, including separate worker data and control storage.
- Allow the supplied host examples to use a configured SmolVM Unix socket.
- Add the engineering blog and strengthen runtime fixtures and CI checks.

Release validation runs on Linux. The earlier macOS results remain historical
evidence for the unchanged library; this patch does not claim a new macOS run.

## 0.1.0

First release of the development-qualified SmolVM client and supervised execution
runtime. Promotes RC2's API and behavior; public APIs and persisted record formats
are unchanged. Production resource/isolation certification remains outside this
release's scope, and unsupported hard controls remain rejected.

- Publish installation through Hex and versioned API documentation through HexDocs.
- Provide typed SmolVM 1.14.1 client operations and explicitly supervised execution
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

- Typed client for pinned SmolVM 1.14.1 health/readiness, machine lifecycle,
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
prepared dispatch. SmolVM 1.14.1 may retain 20/10 GiB templates while reporting a
smaller request; examples use profile revision v2 with those disk sizes and
768 MiB host overhead. Existing saved specs are never rewritten. Inspect their
original identities instead of resubmitting changed specs under the same key.

Reservations do not certify host resource quotas. A bounded Linux disk-full
experiment could stop its guest but could not commit deletion because the worker
database shared the exhausted storage. Retain capacity until verified cleanup or
an explicitly evidenced operator recovery. Canonical workspace containment is
also unsupported: packed-image reads can follow guest symlinks beyond the
lexical workspace. No host path is extracted from guest archives.

SmolVM provides no verified durable exec receipt or deduplication fence. An
original delayed request can start a VM after a successful stop; cleanup retains
uncertain evidence and reservations through the configured deadline/retention
policy. Stronger guarantees and unsupported hard controls are rejected or
explicitly excluded. See the compatibility, recovery and security guides for
measured behavior and unqualified boundaries.
