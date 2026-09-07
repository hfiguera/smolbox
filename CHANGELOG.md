# Changelog

## 0.1.0-dev

Unreleased. Implementation and development-host verification are substantially
complete; resource-profile certification, protected CI and release acceptance
remain open. No production isolation profile is certified.

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
measured behavior and remaining qualification.
