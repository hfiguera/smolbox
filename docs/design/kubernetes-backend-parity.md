# Kubernetes backend parity matrix

Status: baseline version 1, November 13, 2026. The long-term goal is equivalent
SmolBox public domain behavior across HTTP, Embedded and Kubernetes. Follow
[the design](kubernetes-backend.md), [delivery plan](kubernetes-backend-implementation-plan.md),
and [implementation status](kubernetes-backend-progress.md).

Existing HTTP/Embedded support remains subject to its documented package,
platform and per-capability qualification. This matrix identifies contracts to
preserve; it does not expand their existing qualification claims. Kubernetes
runtime-only evidence is not marked as an implemented library capability.

| Domain contract / reference | HTTP and Embedded baseline | Kubernetes status | Delivery gate |
| --- | --- | --- | --- |
| Target admission, fixed resources, effective offline policy | Existing target/package/profile approvals | Runtime recipe and typed target validation complete; runtime admission disabled | Phases 0–3, then public Phase 7 |
| Disposable submit/fetch/await/cancel | Existing managed execution API | Planned; no backend implementation | Phases 1–7 |
| Foreground binary output and real exit | Existing exec contracts | Runtime WebSocket v5 probe passed; Elixir transport pending | Phase 4 + public qualification |
| Bounded input files and artifact collection | Existing file/ArtifactStore contracts | Planned | Phase 5 + public qualification |
| Durable intent, ownership, no replay, positive cleanup | Existing store/backend evidence contracts | Immutable intent/receipt/proof types complete; persistence and provider pending | Phases 2 and 6–7 |
| OCI image/source approval | Existing qualified source catalogs | Public Python manifest pinned and exact catalogs validated; disposable OCI admission pending | Phases 1–3 and 7 |
| Production node evidence, multi-node failure recovery, measurements | Existing backend-specific operational contracts | Planned after preview | Production foundation milestone |
| Private credentials, broader artifacts, image operations | Existing qualified source/image APIs | Planned after preview | Sources/connectivity milestone |
| Network allowlists and ports | Existing qualified network policies/mappings | Planned after preview | Sources/connectivity milestone |
| Retained machines, attached commands, persistent data | Existing managed machine lifecycle | Planned after preview | Retained machines/storage milestone |
| Volumes and disk growth | Existing qualified storage capabilities | Planned after preview | Retained machines/storage milestone |
| Command stdin, guest users, broader guest paths | Existing qualified extended exec/files | Planned after preview; upstream EOF race must be resolved/qualified | Extended execution milestone |
| Startup workloads, background exec, logs and terminals | Existing qualified optional execution families | Planned after preview | Extended execution milestone |
| Exports and checkpoint capture/restore | Existing qualified publication/saved-state APIs | Planned after preview | Saved-state/publication milestone |
| Branches, dependencies and backing reservations | Existing qualified branch lifecycle | Planned after preview | Saved-state/publication milestone |

Update individual rows with implementation references, exact live evidence and
named blockers as capabilities land. Unqualified features remain explicitly
unsupported. Preview completion requires all first-release rows; long-term
parity requires every domain capability and its recovery/cleanup semantics.
