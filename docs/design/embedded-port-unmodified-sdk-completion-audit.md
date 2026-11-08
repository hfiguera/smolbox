# Unmodified SDK migration completion audit

Audit scope: every numbered item and exit gate in the
[implementation plan](embedded-port-unmodified-sdk-implementation-plan.md), plus
the design's preserved behavior and completion criteria. Crash/CLI-race campaigns,
distribution approval and implementing Rustler/Kubernetes are explicitly outside
this ordinary development scope. All in-scope items are implemented and verified;
the final Linux bare-VM fixture passed, restored inventory and ended with no
native owners before normal lab shutdown.

The [ordinary evidence](../evidence/embedded-port-unmodified-sdk-ordinary.json)
records exact package/source/asset identities, toolchain/proof digests and actual
cleanup. Historical patched-package results do not qualify clean bytes. Private
logs, receipts, keys and approved local packages remain outside Git.

## Numbered implementation requirements

| Plan item | Implementation and authoritative verification |
| --- | --- |
| 0.1 | [API audit](../../native/clean-sdk-api-boundaries.md), removed-patch history and active-source searches identify the five replaced APIs/hooks. Remaining template-environment references clear/reject legacy overrides. |
| 0.2 | `native/vendor/source.json` binds revision, tree, archive and all 290 exported source-file hashes/executable modes. Both materialized trees pass `bootstrap.py --check` / `--clean --check`. Research checkout is not a build input. |
| 0.3 | `native/Cargo.toml` declares exact `=1.22.0` verified path dependencies; `Cargo.lock` locks registry inputs. Offline Linux/macOS builds succeeded. SDK source delivery is an ordinary clean pin. |
| 0.4 | `bootstrap.py` rejects patches, Cargo patch/replace tables and SDK dependency aliases that bypass verified source. Python source contracts pass; complete source bytes are checked, not only `patches: []`. |
| 0.5 | API audit and independent compile fixture cover public transfers, lifecycle, seeding, existing-disk formatting and boot. `sdk_compat.rs` / `sdk_schema.json` isolate internal lock/schema knowledge. |
| 0.6 | Clean manifest schema 2 binds compiled source/policy and new identities. Helper/package/config/channel tests reject legacy approval or Hello substitution. Historical manifests remain historical. |
| 0.7 | Selected non-VM worker, actual resolver and copied launcher/guard fixtures passed before ordinary VM qualification; SDK carries the exact configured launcher path. |
| 1.1 | `host.rs` captures generic owner PID/birth/UID, domain, epoch, package and executable locators. Durable receipts and child/transport IDs remain separate. |
| 1.2 | `transfer_worker.rs` bounds private frames before allocation and receives no creation receipt/runtime authority. Selected local-protocol peer checks prove SDK agent access without VM startup. |
| 1.3 | `transfer_supervisor.rs` owns exact child handles/birth identities; normal collection and deterministic retirement tests pass. Linux sibling-safe reaping and stopped-helper child samples pass. No unrelated-child sweep. |
| 1.4 | Four active worker permits, 64-MiB engine spool budget and descriptor-limit admission preserve four work/two control slots. Host spawn failures occur before file SDK dispatch. Exhaustion/retained-permit tests pass. |
| 1.5 | Decoder/evidence, framing/correlation, admission, malformed messages, staging cleanup and modeled collection tests pass without live owner-loss campaigns. |
| 2.1 | Worker calls public `AgentClient::connect`, capped read and exact-reader write. Engine/bridge have no calls to the removed socket/timeout hooks. |
| 2.2 | `files.rs` retains receipt/machine/source/domain leases in the controller; activation requires running evidence. Worker does not attach/start a VM. |
| 2.3 | Monotonic file expiry covers staging/queue/connection/collection; retirement cannot reset its clock. Unresolved collection retains leases and disables admission. |
| 2.4 | Private spools/IPC, Port upload credit and bounded public forwarding preserve 16-MiB transfers, 64-KiB chunks and exactly one terminal. Protocol 1.4 explicitly declares cancellation grace/unavailability. |
| 2.5 | Correlated SDK acknowledgment is separate from child exit/cancellation. Late ACK and uncertain write tests pass; guest rollback/replay is never inferred. Cleanup checks owned spool inode. |
| 2.6 | Exact/short/overlong uploads, capped/fragmented reads, invalid fields, modeled cancellation/deadline, siblings and quiescence contracts pass. Ordinary binary files pass on both platforms. |
| 3.1 | API audit / `assets.rs` cover home/helper/boot plain and compressed order. Actual clean-resolver tests exercise precedence/expansion/restart. |
| 3.2 | Public pack materialization/seeding and SDK formatting prepare approved disks. Missing home templates install sparsely under domain ownership. Container and bare-VM paths are separately qualified. |
| 3.3 | Hash/geometry/stamp checks reject missing/conflicting/redirected candidates and fallback. Installation never overwrites conflicts or changes HOME. Backing permission normalization affects newly owned files only. |
| 3.4 | Legacy resolver hook is unused. Sparse geometry, compressed/plain equality, conflicts, changed candidates and real resolver checks pass. |
| 3.5 | Account package/domain references persist; restart tests preserve them. Builder preserves already matching baseline template bytes, regenerates compression and assigns identities to changed bytes. |
| 4.1 | `domain.rs` account/domain locks and `gate.rs` per-machine movable gates coordinate both future bridges. Duplicate owner and public target-domain/config tests reject before launch. |
| 4.2 | `machine.rs` verifies full receipt, marker/material, dependent clones and PID/birth immediately before ordinary lifecycle SDK calls. Non-VM self-contention tests prove no outer source flock around lifecycle. |
| 4.3 | Preconditions are `NotDispatched`; errors after SDK entry/post-observation are uncertain. Tests and documentation explicitly limit protection to cooperating owners. |
| 4.4 | `sdk_compat.rs` opens existing SQLite read-only/query-only, pins inode and checks supported schema/integrity/sidecars. Tests prove no migration, repair, reservation reaping or SDK writer observation. |
| 4.5 | Epoch fencing and per-name actor/handle/material quiescence precede positive absence. Rows, reservations, partial material and unrelated inventory never mint ownership. |
| 4.6 | Unknown schema, corruption, replacement, redirection, contention and unresolved actors cannot release capacity. Native observation, Runtime unavailable/unknown and PostgreSQL binding/reservation contracts pass. |
| 4.7 | Temporary-DB, in-memory/fake-Port and PostgreSQL contracts cover no replay and conservative recovery. v16/legacy HTTP/fresh-BEAM codec tests pass in the ordinary Elixir suite. |
| 5.1 | Immutable epoch-specific approved launcher copy/context uses the clean SDK's existing boot-binary path. Parent identity is captured before spawn; no mutable global owner file. |
| 5.2 | Context/executable UID, mode, hash, path and epoch checks pass. macOS copied signature/library loading and ordinary Linux/macOS launch passed with exact clean packages. |
| 5.3 | `BootLauncher::arm_current` validates context/parent and synchronously starts the watcher before SDK config/boot; epoch enrollment must correlate with SDK dispatch/result. Invalid guard and modeled identity tests pass. |
| 5.4 | Source review checks descriptor closure and Linux allowed getppid/sleep/exit syscalls. Non-VM guard fixture proves ordering/enrollment; ordinary VMs prove successful boot. Abrupt loss remains unqualified. |
| 5.5 | Host/owner/executable context is generic and contains no NIF terms or Port startup requirement. Shared engine owns policy; transport adapters translate it. |
| 5.6 | Design/API audit define clean SDK configuration, bounded executors, asynchronous destruction and no overlapping owners. `native/policy.json` leaves Rustler disabled; BEAM environment is not mutated. |
| 6.1 | Five active patch files/application logic are removed. History README links recorded commits; active templates/lifecycle/absence/boot paths use replacements. |
| 6.2 | CI ordinary native check verifies both full source inventories before/after tests and forbids downstream configuration. Linux/macOS completed checks pass. |
| 6.3 | Manifest/source/policy digests bind worker/guard/observation/exclusive-owner policy; schema 2 / Hello 1.4 negotiate exact metadata and grace. Legacy Hello 1.3 cannot satisfy clean approval. |
| 6.4 | v16 payloads exclude runtime handles; legacy HTTP bytes/readers remain supported. Assignment/domain/package mismatch and future/unknown vocabulary tests pass; no automatic record relabeling. |
| 6.5 | New exact Linux x86_64/macOS arm64 development packages built and passed inventory/runtime checks. macOS signature/hypervisor entitlement verified; Linux digest approval retained. Release signing is separate. |
| 6.6 | Setup/examples/consumer defaults explicitly select ordinary/public mode; omission rejects native consumers. Native check never selects deferred live campaigns or all ignored tests. Failure runners retain authority and use normal shutdown. |
| 7.1 | 77 engine, 17 helper, seven protocol tests on each platform; selected worker/guard/resolver checks, Linux normal reaping, Python contracts, fmt/Clippy/Rustdoc, 754 ordinary Elixir cases and 93 PostgreSQL tests per platform passed. |
| 7.2 | Exact clean packages passed ordinary resources/commands/files/retention/draining/helper replacement/deletion on both platforms. SDK inventories restored; Linux stopped-helper child counts zero. |
| 7.3 | Current/minimum fresh public consumers without Rust passed on both platforms. HTTP-only consumers without native assets passed. Full ordinary contract suite includes HTTP client/compatibility regressions. |
| 7.4 | Real encrypted PostgreSQL public lifecycle passed normal Runtime replacement with surviving store on both platforms. Deterministic unknown/schema-failure tests cover uncertain cases; no persistence interruption injected. |
| 7.5 | Setup/design default patched-to-clean migration to old-package drain/delete and fresh clean enrollment. Old assignment readers retained; unknown reservations prohibit resets/adoption. Helpers are only swapped for explicitly qualified compatible clean pairs. |
| 7.6 | Setup, API audit, progress, source/license review and exact evidence state narrower independent-writer protection, process overhead, verified absence and deferred gates. Historical Linux fault failures remain unresolved, not relabeled. |

## Preserved boundaries and remaining gates

Source verification, deterministic contracts and ordinary evidence collectively
cover the development contract; none is substituted for a live fault campaign.
Independent SDK/CLI writers remain unsupported. A worker exit is not a guest
acknowledgment. Unresolved native actors preserve leases/reservations and close
admission; no automatic replay, generation reset or adoption is authorized.

The SDK's internal qcow2-export VM is not an exposed backend capability. The
private fixture author instead uses an explicitly selected host converter with
the source stopped/full-receipt checked under its source/domain locks, followed
by public SDK asset collection/manifest seeding/packing. It changes no SDK source,
starts no extra VM and does not add a consumer dependency. Its final Linux and
macOS results passed with exact tool/package hashes and restored inventories.

Crash, pre-main pauses, watcher failure, live persistence interruption and
destructive CLI-race validation remain deferred. Developer ID/notarization,
publisher provenance and complete firmware/kernel corresponding-source/license
delivery remain distribution gates from the release gap assessment. This work
publishes nothing. Rustler activation needs a clean SDK API audit/initialization
upgrade; implementing it or Kubernetes is not part of this migration.
