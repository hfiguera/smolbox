# Implementation and verification plan

The source objective is the complete community-workspace request in the task. Completed items are backed by docs/validation.md and the retained evidence.

- [x] Phoenix LiveView app consuming Hex 0.2.0; share PostgreSQL adapter without duplicate implementations.
- [x] Private explicit setup, database migrations, read-only readiness, loopback binding.
- [x] Durable workspace and action identities; idempotent submissions; no unknown replay.
- [x] Lifecycle controls, state, cancellation and history with bounded output.
- [x] Real PTY browser input/output/resize/exit; explicit disconnect semantics.
- [x] Managed upload/download, approved paths and 16 MiB bounds.
- [x] Self-contained startup sample service, fixed port mapping, background and optional >300s demo.
- [x] Tests for database, lifecycle conflicts, duplicate requests, recovery, files, terminal, unavailable/unknown states and deletion.
- [x] Desktop/mobile keyboard and browser interaction validation.
- [x] Full real-worker browser walkthrough with PostgreSQL, app restart, stop/start, deletion and capacity evidence.
- [x] README, architecture, walkthrough, recovery/cleanup, discoverability and CI.
- [x] Impeccable final critique, detector and design documentation.
- [x] Existing examples and repository checks remain valid; published package unchanged.
