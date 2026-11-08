# Embedded Port durable recovery proof

This is internal qualification of the native runtime and the host-owned
PostgreSQL example. The historical runs below preceded public development
admission. Public application setup is now described in `docs/embedded-port.md`. The proof
constructs an internal normalized target after validating durable store
capabilities; this is not an application setup example or an admission bypass to
copy into production code.

Use one exclusively controlled native SDK account domain, an already enrolled
domain generation, a verified native package, and an approved offline
`.smolmachine` fixture. Keep the same package, fixture, domain, database and private
output directory across phases. Apply all example migrations before starting.
The proof captures the package manifest digest and refuses a changed package on
recovery. Each phase runs only once; the output contains private fsynced keys,
intent and receipt snapshots. Do not replay an interrupted phase blindly.

The script uses the real encrypted PostgreSQL store in durable mode, including
authenticated projections and atomic native assignments. Its artifact adapter
rejects all calls: this particular proof has no artifact-store inputs or saved
outputs and makes no artifact persistence claim.

Preparation defaults to a container pack. Creation/start fixtures use numeric
guest user 65534:65534. Exec fixtures use 0:0 so a replay could actually write
their marker or counter in the root-owned workspace. The `exec-result` case
checks that the counter advances exactly once.
For an approved bare-VM pack, add `--guest-mode vm` to the `prepare` command or
SIGKILL runner. This captures VM mode in the private proof configuration and uses
no explicit guest user, as required by the engine's VM policy. Recover/verify use
that saved choice. Existing proof configurations without this field retain the
container default; the proof does not infer mode from labels or inventory.

From `examples/durable_host`, with the example's explicit PostgreSQL environment
(`DATABASE_URL`, or the `SMOLBOX_DATABASE_SOCKET_DIR` and related variables):

```sh
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix run scripts/embedded-recovery-proof.exs \
  --phase prepare \
  --package /approved/native/package \
  --fixture /approved/offline.smolmachine \
  --sha256 APPROVED_FIXTURE_SHA256 \
  --domain-json /private/enrolled-domain.json \
  --output /private/new-durable-proof
MIX_ENV=test mix run scripts/embedded-recovery-proof.exs \
  --phase recover --output /private/new-durable-proof
MIX_ENV=test mix run scripts/embedded-recovery-proof.exs \
  --phase verify --output /private/new-durable-proof
```

`prepare` executes a disposable command with real Exit 7 and completes verified
deletion. It creates and starts a retained machine, pauses an attached command
after the SQL dispatch-intent commit and before native dispatch, and replaces the
owner. The stale pinned task cannot send through the new channel. It leaves the
command unknown without Exit, its slot blocked and the complete retained
reservation. Runtime shutdown preserves the receipt and stopped storage.

`recover` starts a fresh BEAM with the same database, encryption key and native
domain. Automatic reconciliation must observe the same stopped full receipt,
retain the unknown command and blocked slot, and preserve exactly one reserved
slot. Explicit stopped resolution clears the slot without inventing Exit. Only
then does a new explicitly started command check the persistent guest replay
marker is absent. Explicit stop and delete must observe absence before releasing
capacity. The SDK inventory must equal its original baseline. A third BEAM in
`verify` checks released tombstones, unchanged historical unknown commands and
zero reserved capacity. All stages decrypt actual SQL ciphertext and round-trip
the records through the codec.

For SIGKILL, choose a boundary with `--fault` and use a separate new output
directory and the runner below in place of `prepare`:

```sh
MIX_ENV=test python3 scripts/embedded-recovery-kill.py \
  --fault exec-intent \
  --package /approved/native/package \
  --fixture /approved/offline.smolmachine \
  --sha256 APPROVED_FIXTURE_SHA256 \
  --domain-json /private/enrolled-domain.json \
  --output /private/new-kill-proof
MIX_ENV=test mix run scripts/embedded-recovery-proof.exs \
  --phase recover --output /private/new-kill-proof
MIX_ENV=test mix run scripts/embedded-recovery-proof.exs \
  --phase verify --output /private/new-kill-proof
```

The runner owns the BEAM as a direct child and verifies its live PID before
SIGKILL. It never kills the helper or VMM. It waits for the captured helper process
to exit after owner loss before starting another authority. SQL still contains a
dispatching command at this boundary; the fresh runtime must classify it unknown
without replay. Recovery requires the runner's recorded signal/exit evidence.
The available boundaries are:

| Fault | Pause before SIGKILL | Fresh-process assertions |
| --- | --- | --- |
| `exec-intent` (default) | SQL dispatch intent committed, before native send | Unknown command has no result; no replay marker; explicit stopped resolution clears its slot. |
| `exec-result` | Real Exit and output returned, before the first SQL result write | Result remains unknown and absent from SQL; after explicit resolution, a new command reads a persistent counter of exactly one. |
| `create-intent` | SQL creation intent committed, before native send | Missing receipt remains reserved; explicit intent-bound absence resolution releases it. |
| `create-receipt` | Real creation receipt returned, before its SQL write | Present material remains unverified and reserved; matching labels do not confer ownership. |
| `start-receipt` | Real running observation returned, before its SQL write | Owner loss stops the VM; recovery preserves the saved full receipt and reservation without replaying start. |

All nondefault boundaries require the SIGKILL runner. Creation/start cases also
preserve the independently completed Exit-7 history. Each `verify` runs in a
third fresh BEAM and checks the same tombstone and released accounting. The
script rejects reuse of a BEAM OS PID across these phases.

For `create-receipt`, preparation saves the authentic reply in a private
out-of-band file. Recovery first proves that automatic reconciliation and an
explicit deleted resolution leave the receipt-less SQL record reserved while
material exists. A separate fixture-maintenance action uses the authentic full
receipt to inspect stopped state and delete that material. The receipt is never
adopted into the durable record. Only subsequent verified absence resolves that
record and releases its reservation. Likewise, the out-of-band exec result is
evidence for the fault checkpoint and is never adopted into SQL.

These checkpoints do not qualify killing the helper during live exec, boot-time
parent loss, all fault cases or other platforms. They interrupt the BEAM at the
specified persistence boundaries after observing an authentic reply where stated.

On failure, inspect the saved records and physical state. For this proof's retained
machine, an explicit disposal phase uses its saved full receipt. It resolves an
unknown slot only after observing stopped state, then explicitly deletes and
verifies capacity release:

```sh
MIX_ENV=test mix run scripts/embedded-recovery-proof.exs \
  --phase dispose --output /private/interrupted-proof
```

For receipt-less creation trials, disposal uses the saved authentic out-of-band
receipt if available, followed by explicit intent-bound absence resolution. It
does not sweep SDK names or labels or manufacture a receipt. If material exists
without a saved authentic receipt, absence resolution must leave it reserved.
This proof does not resolve uncertain disposable creation.

## Recorded macOS evidence

On October 11, 2026, five SIGKILL sequences passed against protocol 1.3 package
manifest SHA-256
`7066c758f9d4286bbf659c00a3bb23e822ee17848a06f9dd0de713f133a5b726`,
with the same approved container fixture and SDK revision recorded below.
The host used macOS arm64, Elixir 1.20.4 / OTP 29.0.6 and PostgreSQL 17.11.

| Fault | Private evidence directory under `.local/` | Prepare / recover / verify BEAM PIDs |
| --- | --- | --- |
| `create-intent` | `embedded-durable-create-intent-final/` | 22953 / 23201 / 23386 |
| `create-receipt` | `embedded-durable-create-receipt-proof/` | 23531 / 23806 / 23981 |
| `start-receipt` | `embedded-durable-start-receipt-proof/` | 25934 / 26452 / 26841 |
| `exec-intent` | `embedded-durable-exec-intent-writable/` | 30896 / 31261 / 31409 |
| `exec-result` | `embedded-durable-exec-result-qualified/` | 29919 / 30527 / 30748 |

Each runner recorded signal 9 and helper exit. Each recovery and third-process
verification passed with zero reservation and inventory equal to its empty
baseline. Creation-reply recovery kept present material unverified until explicit
full-receipt fixture maintenance and a later absence query. Start-reply recovery
observed stopped state without replay. Exec-result recovery preserved unknown
history with no persisted result and observed a replay counter of one.
The exec-intent rerun used a writable marker; the earlier non-root fixture could
not write into its root-owned workspace and is not sufficient evidence for that
marker assertion. Failed fixture/checkpoint trials were explicitly disposed using
authentic receipts or verified absence; they are not passing qualification runs.

The scripts evolved during these trials; the recorded package and fixture stayed
unchanged. The final script hashes recorded in the progress log identify the
committed tools, not identical tool bytes for every earlier trial. The public
admission gate and broader fault/platform requirements remain open.

On October 10, 2026, macOS arm64 with Elixir 1.20.4 / OTP 29.0.6 and the encrypted
PostgreSQL 17.11 example passed both three-process sequences. The signed package
manifest SHA-256 was
`33cb3d38c7a80db56d590a41d01e8a68ca2f9645b0fb15fa75e7674c105464df`,
using SDK revision `9f446ae00219148ca4a703914f44a8e2fab11655` and the approved
fixture SHA-256
`0f4a26a548738c6ba359701ea23c5d2bbb93f0c1d95f6444df897bfa99e27aa2`.
The fixture used one CPU, 512 MiB guest RAM, 1 GiB storage and 1 GiB overlay; the
host reservation included 256 MiB overhead. These describe configured resources
and verified reservation accounting; they do not qualify host quotas.

Private evidence is in `.local/embedded-store-postgres/durable-native-*-final.log`
and `.local/embedded-durable-native-proof-final/` for owner replacement plus fresh
BEAM recovery, and `.local/embedded-store-postgres/durable-native-kill*.log` and
`.local/embedded-durable-native-kill-proof/` for the SIGKILL boundary. The respective
BEAM OS PIDs were 93683/94037/94214 and 94486/94833/95302. Both sequences ended
with empty native inventory and zero retained reservation. The PostgreSQL rows,
encrypted snapshots and private keys remain available for evidence review.

Both sequences also passed after the protocol 1.2 qualification query was added,
using rebuilt signed package manifest SHA-256
`57510c90cc95cf85039f65d032a39150aa89b60c5fcf7ad20c179e1c3d94edf2`
and the same SDK/fixture pins. Owner-replacement evidence is in
`.local/embedded-durable-qualification-proof/` with logs
`.local/embedded-store-postgres/qualification-{prepare,recover,verify}.log`;
BEAM OS PIDs were 169/539/957. SIGKILL evidence is in
`.local/embedded-durable-qualification-kill-proof/`, its sibling `-prepare.log`,
and `.local/embedded-store-postgres/qualification-kill*.log`; the BEAM OS PIDs
were 1692/2117/2374. The runner recorded signal 9 and observed helper exit.
Each fresh verification preserved the deleted full-receipt tombstone, unchanged
unknown history and zero reservation; both inventories matched their empty
baseline. PostgreSQL passed 93 contract tests, 29 lab cases excluded, in
`.local/embedded-store-postgres/qualification-contracts.log`. The private cluster
was stopped after verification. These reruns qualify the same dispatch-intent
boundary for the new package, without broadening the fault matrix.

After streaming sidecar-content and disk-geometry validation, the
owner-replacement sequence passed with final signed manifest SHA-256
`3a6694c74bf811f8972e53fc1260ceb510353c5042b6db2464a7f27f602a30c0`.
The BEAM OS PIDs were 6199/6610/6799. Private snapshots are in
`.local/embedded-durable-archive-proof/`, with logs
`.local/embedded-store-postgres/archive-{prepare,recover,verify}.log`. Fresh
verification preserved the deleted receipt/assignment tombstone and unchanged
unknown command, with zero reserved slots and inventory matching the empty
baseline. PostgreSQL passed 93 contract tests, 29 lab cases excluded, in
`.local/embedded-store-postgres/archive-contracts.log`. The private cluster was
stopped after these checks. This package has not rerun the SIGKILL boundary;
the distinct package identities above remain part of that evidence's scope.

The bare-VM exported fixture also passed both sequences after adding
`--guest-mode vm`. Its SHA-256 was
`d5d1258339d7fae03d3ddb448ac907f906440c73cfd24b9098e13a2d357e2c8b`.
Owner replacement used intermediate signed package manifest SHA-256
`43c11e14e542c6d36bf8c8a9614e6f3f1ee39fd3ab586ed6a334b668431bee63`,
with BEAM OS PIDs 8377/8832/9263. Evidence is in
`.local/embedded-durable-vm-proof/` and
`.local/embedded-store-postgres/vm-{prepare,recover,verify}.log`.
The SIGKILL sequence used final signed package manifest SHA-256
`2f21216070495a40b89e6346d512b5a15ee974d62af97a0a6e7b620739e49f40`,
with BEAM OS PIDs 10177/10317/10603. Evidence is in
`.local/embedded-durable-vm-kill-proof/`, its sibling `-prepare.log`, and
`.local/embedded-store-postgres/vm-kill*.log`. The runner recorded signal 9 and
observed helper exit. Both sequences preserved unknown without replay, resolved
the stopped full receipt explicitly, verified deletion and released capacity.
Fresh verification preserved the tombstone and unchanged unknown history;
inventories matched their empty baselines. PostgreSQL passed 93 contract tests,
29 lab cases excluded, in `.local/embedded-store-postgres/vm-contracts.log`.
The private cluster was stopped after verification. This extends the recorded
dispatch-intent boundary to VM-mode creation; the broader fault matrix remains
unqualified.

No Linux evidence or public first Port release is claimed. See the
[implementation plan](embedded-port-implementation-plan.md) and
[progress record](embedded-port-progress.md) for the remaining admission,
interference, fault, package-consumer and distribution gates.
