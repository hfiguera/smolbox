# A persistent SmolBox workspace

A small Phoenix LiveView app that combines the **published SmolBox 0.2.0 package**
with a real persistent machine. Create a workspace, move project files, run
commands, use a browser terminal, open its Python service, leave, and return to
the same computer. Stop/start preserves files; only explicit deletion removes it.

This is a local, single-user learning example, not a hosted IDE or tenant boundary.
The app binds to loopback. It uses one dedicated worker and PostgreSQL; there is
no memory-store fallback. Keep the repository's `examples/support/store` and
`examples/durable_host/priv/repo/migrations` directories when copying it.

## Prerequisites

- Elixir 1.18+ / compatible OTP; CI uses Elixir 1.20.4 / OTP 29.0.6.
- Node.js 22+ and npm; PostgreSQL 16+ with a dedicated database.
- Native smolvm **1.17.0**: Linux x86_64 with KVM, or macOS Apple Silicon.
- One approved native Python image ending in `.smolmachine`, containing `python3`,
  `/bin/sh`, `/bin/true`, and ordinary shell tools. Follow the repository's
  [artifact preparation](../../docs/client.md) and
  [platform prerequisites](../../docs/compatibility.md), including working host
  `resize2fs` for shrinking disks. This app does not pull or build images.
- A qualified 2 GiB storage + 2 GiB overlay configuration and 768 MiB VMM allowance.
  Larger templates need a revised approved profile/capacity in `Workspace.Settings`
  **before** initial creation. Reservations are accounting, not hard host quotas.
- A private worker running with `SMOLVM_FILE_TRANSFER_MAX_BYTES=16777216`.
  Keep its original private HOME/data/config/runtime environment on every restart.
  Do not point other independent store authorities at this worker.

Run the controller on the worker host: setup hashes the local approved image at
the path the worker will use. For a remote Linux host, `ssh linux` is available in
our development environment. Run the app there and forward its browser/service
ports (`ssh -L 4000:127.0.0.1:4000 -L 18080:127.0.0.1:18080 linux`). The preview URL
is an address reachable by **your browser**, not necessarily the controller.
Upstream port mappings may listen beyond loopback; restrict the dedicated host's
network access. Worker credentials are never sent to the browser.

## Quickstart

From the repository root:

```sh
cd examples/community_workspace
mix deps.get
npm --prefix assets ci
mix assets.build

# Use your PostgreSQL role/credentials. The database must already exist.
createdb smolbox_workspace
export DATABASE_URL=ecto://localhost/smolbox_workspace
export SMOLBOX_WORKSPACE_HOME="$PWD/.workspace"
export SMOLBOX_RUNTIME_SOCKET=/absolute/private/path/smolvm.sock
export WORKSPACE_IMAGE=/absolute/path/python.smolmachine
# macOS: shasum -a 256 "$WORKSPACE_IMAGE"; Linux: sha256sum "$WORKSPACE_IMAGE"
export WORKSPACE_IMAGE_SHA256=the_verified_64_character_lowercase_digest

mix workspace.setup --worker-url http://localhost \
  --image "$WORKSPACE_IMAGE" --sha256 "$WORKSPACE_IMAGE_SHA256" \
  --service-port 18080 --preview-url http://127.0.0.1:18080/
mix workspace.check
mix phx.server
```

Open [localhost:4000](http://localhost:4000). Set `PORT` to change the app port.
Start the dedicated worker separately with its qualified environment, for example
`smolvm serve start --listen unix:///absolute/private/path/smolvm.sock`.
For HTTP loopback, omit `SMOLBOX_RUNTIME_SOCKET` and pass the actual worker URL.
For an authenticated HTTPS proxy, use `SMOLBOX_PROXY_TOKEN`; TLS verification stays
on. Setup also accepts `--platform linux|macos` and `--architecture x86_64|aarch64`.

`workspace.setup` creates private keys/configuration and runs the shared store
migrations plus the workspace UI migration. It creates no machine and preserves
existing settings/keys on subsequent runs. `workspace.check` reads configuration,
migration readiness, store capabilities, health/version and readiness without
starting a controller or mutating a machine. An unavailable worker/database is
never treated as an absent machine. Check the configured image digest and file
permissions if readiness says configuration is invalid.

Keep PostgreSQL, the private `.workspace` directory, artifact, and worker disks.
The directory contains stable fingerprint/encryption/web keys and collected files.
Do not regenerate keys to fix an error. Never place it in a guest-accessible path.

## Walkthrough

1. **Create workspace**, then **Start machine**. Creation and starting are separate
   durable lifecycle operations. The header shows the retained identity.
2. Upload a project file under `/app/project`, or configuration under
   `/home/dev/.config`. The limit is **16 MiB per file**. Upload a 2 MiB file to
   exercise the larger-transfer policy. Collect it, then download from Activity.
3. Run `pwd; ls -lah; cat starts.txt`. Run another command to read a file written
   by the first. Foreground commands accept **1–600 seconds**; the optional
   “Run beyond five minutes” sample waits 305 seconds with a 330-second budget.
   Output is bounded to 64 KiB and appears on completion.
4. Open the terminal, type `cd /app/project`, edit/read a file, and resize the
   browser or terminal area. Escape moves focus to the terminal control. Type
   `exit` and wait for “Terminal exited” before refreshing, leaving the page, or
   restarting the controller. The browser warns when leaving with an active shell
   when it supports unload prompts. Brief browser interruptions can reconnect as
   described below; an app restart still needs a clean shell exit.
5. Choose the background sample and run it. Activity displays a typed
   `SmolBox.LaunchResult` PID. This confirms launch, not continued life, readiness,
   eventual exit, or supervision. The process appends a marker then sleeps.
6. Open the mapped service. The startup workload runs `python3 -c ...` with
   `WORKSPACE_NAME=My workspace`, working directory `/`, and TCP host 18080 → guest
   8000. It creates `/app/project` and its initial `index.html` **before** serving;
   no upload must win a race with startup. It never overwrites an existing index.
   Edit that file and refresh the service page. Each start appends `starts.txt`.
7. Finish foreground work and exit the terminal. Stop only `mix phx.server`, then
   run it again with the same environment. Reopen the browser: identity, files,
   command history, and background launch evidence remain. No command is replayed.
8. **Stop machine**, then **Start machine**. Files remain; the startup HTTP service
   returns. The separate background launch is not replayed. This sample explicitly
   uses restart policy `never`; unsupported automatic restart is not offered.
9. **Delete → Confirm deletion**. Wait for **Deleted**, verified absence and
   reservation release. Activity and collected downloads remain. This identity
   cannot create a new, empty replacement machine.

Console diagnostics are VM/worker console output. smolvm 1.17.0 discards the
startup workload's stdout/stderr; the app does not label console bytes as
application logs. A running VM alone does not prove the HTTP service is ready.

Commands, Files, Terminal, and Activity links jump directly to their sections.
Activity shows the latest two requests with earlier entries expandable. File
collection defaults to `/app/project/starts.txt`, created by the startup workload;
the chosen path persists across updates. Create the optional `artifact.bin` sample
before collecting it. Missing, unreadable, non-regular or oversized files produce
**Failed / Exit 1** with a useful message, without blocking the workspace. Downloads
keep the workspace and its terminal connected.

## Identity, retention and recovery

`Workspace.Workspaces` calls public `SmolBox.Machines`, `SmolBox.Terminal`, and
artifact-store APIs. The shared PostgreSQL adapter remains the only durable
ownership, scheduling and capacity authority. `workspace_homes` stores the stable
workspace/machine mapping; `workspace_actions` stores encrypted action payloads
and durable request identities. Form identities survive reconnects in tab session
storage. After a reload, submitted command fields and file paths are restored from
the encrypted ledger alongside that identity; command text is not saved in browser
storage. Unsubmitted drafts and local file selections are not restored. Loading a
sample selects `/app/project` as its working directory. Unchanged resubmissions
reuse the identity; edits or **New run** deliberately
create another. A changed payload under an existing ID is rejected. An unresolved
lifecycle acceptance is recorded, displayed and never automatically resent.

One managed command/terminal/file operation can occupy the machine at a time.
Uploads stage an input manifest with a managed `/bin/true` execution. Downloads use
a managed Python command to take a bounded snapshot, then collect its output
manifest under the same exclusive command slot. The snapshot always exists after
an ordinary file error, but only a confirmed exit 0 exposes a download. One reserved
staging file, `/home/dev/.config/.smolbox-collection`, is reused, holds at most 16 MiB,
and is outside the project's HTTP document root. Uploading/collecting that exact
path is rejected. A temporary snapshot may require another 16 MiB while copying;
it is atomically replaced and cleaned up on normal completion. Interrupted commands
can leave temporary files for inspection during recovery. Staging bytes remain
on the retained disk until the next collection or explicit machine deletion.
Guest commands can still modify these paths: they are not a sandbox. Concurrent
background writers can change a source during copying, so this is not an atomic
filesystem snapshot. Worker loss, damaged staging directories, or external
interference can still make collection uncertain; recovery safeguards remain.
Stop/delete cannot race active or uncertain work. A confirmed background launch
releases its execution slot while the guest process can continue alongside later
commands or file operations; stopping the VM interrupts that process. Confirmed not-dispatched stale
versions receive bounded retries only after refreshing and rechecking machine state.

Closing a tab, finishing/cancelling a command, or restarting the controller does
not delete the machine. Cancellation can prevent undispatched work; after dispatch
it ends observation without proving guest termination. An unknown outcome retains
its command slot. A browser refresh or lost browser consumer gets a **30-second reconnect window**
on the same app/controller. The app retains the existing PTY attachment, permits
one browser consumer, and resends at most one unacknowledged output frame; it never
replays input or opens a replacement shell. Previously acknowledged output is not
restored. This is browser reconnection to a live controller, not recovery of a lost
worker PTY. Controller restart, worker disconnect, explicit disconnect, or expiry
can still leave an unknown outcome requiring operator recovery. Close shells with
`exit` and wait for confirmed exit before planned controller restarts. The explicit
disconnect and command cancellation actions explain this consequence and ask for
confirmation. Expired or unknown work shows recovery guidance instead of offering
reconnection. Output remains bounded by the existing
64 KiB upstream buffer and one browser-acknowledged frame; slow connected consumers
are disconnected. Session/idle budgets remain 10/5 minutes and do not reset on
browser reconnect.

For an interrupted command/terminal, follow the
[upstream fencing limitations and recovery contract](../../docs/persistent-machines.md#cancellation-and-uncertain-outcomes).
There is deliberately no browser “force unlock” button:

```sh
# Read-only, also works while the app is down:
mix workspace.recover inspect

# Stop ALL controllers sharing this store first. This preserves disks but does
# not establish quiescence by itself:
mix workspace.recover stop-for-drain --controllers-stopped

# Operator step: drain/fence outstanding requests on the dedicated worker.
# Follow the platform's qualified worker shutdown/restart procedure, preserving
# its private configuration/data and the stopped disks. Verify old processes
# and sockets cannot issue late work. Do not use a timer or expired store lease
# as proof. Then, and only then:
mix workspace.recover resolve-stopped --quiesced
mix phx.server
```

The resolution flag asserts **operator-established** quiescence. The tool verifies
the recorded incarnation, stops it again after the drain, resolves the exclusive
slot, and preserves unknown execution history. It never adopts by name. A missing
machine, lost disks, ownership mismatch or lost creation evidence needs the
[explicit absence procedure](../../docs/persistent-machines.md); do not delete DB
rows or replace it with an empty machine. Unavailable stores fail closed.

Reservations survive command completion and stop. This example conservatively
keeps the whole allocation, including disks, until verified deletion. Durable
records recover management; they do not back up worker disks, migrate machines or
restore a lost filesystem. Completed/deleted request identities are retained for
deduplication; plan storage accordingly.

## Tests and evidence

```sh
createdb smolbox_workspace_test
DATABASE_URL=ecto://localhost/smolbox_workspace_test MIX_ENV=test mix test --warnings-as-errors
mix format --check-formatted
mix quality
npm --prefix assets ci
mix assets.build
```

Ordinary CI uses PostgreSQL with simulated worker transport and terminal peers;
it requires no VM. It covers identity, duplicate requests, conflicts, restart,
unknown work, unavailable store/worker, transfers, terminal ownership/backpressure,
browser disconnection, and verified capacity release.

For the **real** walkthrough, use a dedicated disposable demonstration workspace.
The script writes `community.bin`, `retained.txt`, `background.txt`, `index.html`
and starts work; its final phase explicitly deletes when requested:

```sh
(cd assets && npx playwright install chromium)
export WORKSPACE_URL=http://localhost:4000
export WORKSPACE_EVIDENCE="$PWD/.workspace/browser-evidence"
node scripts/browser-walkthrough.mjs before-restart
# Stop/restart only the controller app, preserving its configuration and DB.
WORKSPACE_DELETE=1 node scripts/browser-walkthrough.mjs after-restart
mix workspace.recover inspect
```

Export the JSON evidence before a lab reset. See [validation](docs/validation.md)
for the actual tested platform, failures found and final outcomes. The optional
305-second sample is not required by this fast walkthrough.

## Migrations, cleanup and limitations

The app uses Hex `{:smolbox, "~> 0.2.0"}` with a lockfile, not repository library
code. Shared adapter source moved to `examples/support/store`; the durable host
compiles that same source. Existing store schemas/codecs are unchanged. Setup
adds `workspace_homes` and `workspace_actions` on top of the existing v5 store
migrations. Migration `20260924000001` adds nullable `request_version` to workspace
receipts so start/stop/delete completion is recorded only when SmolBox's
`last_request` matches that accepted version and the target state is observed.
Older receipts lack this evidence and display **Accepted**, never guessed completion.
Run both UI migrations before starting the updated app. Stop the app before a
rollback; retaining the nullable column is compatible with the previous example.
Dropping that column discards receipt correlation evidence, so keep it and the DB
backup when rolling back. Use a dedicated DB; do not automatically upgrade a production store.
There is no app release or package release change.

Before upgrading, stop controllers and back up the DB, private keys/object store
and worker disks together. Workspace migration rollback deliberately refuses to
erase identity history. Rolling back this example means stopping it and retaining
its DB/keys, not running destructive down migrations or older code against new
records. Changing the image/profile under the same machine ID conflicts by design.

After **verified deletion**, stop the app and dedicated worker. Keep DB/key/object
backups if history or downloads matter. Only then explicitly drop the dedicated
DB and remove its private home if you intentionally want to discard all history.
For another demo, use a fresh private home and dedicated database after releasing
the old worker authority. There is no automatic expiry, purge, idle shutdown,
multi-user authentication, image registry, process supervisor, or full IDE.

## Example code-quality checks

Run `mix deps.get`, then `mix quality` from this example directory. The alias
selects `MIX_ENV=test` unless explicitly overridden and runs compilation with
warnings as errors, strict Credo with the ExSlop plugin, ExDNA with a zero-clone
budget, and Dialyzer with `--force-check`. CI runs the same alias. The tools are
development/test dependencies and are not included in production runtimes.

The local Credo configuration includes this app's source, tests, configuration,
scripts and compiled shared example code. ExDNA checks implementation and support
code with the repository's existing `min_mass: 30` threshold; repeated test-case
bodies are outside its scope. Dialyzer analyzes the app's compiled test-environment
modules against its own dependencies. Keep the local `.credo.exs` and `.ex_dna.exs`
when copying an example. A first Dialyzer run builds a PLT and can take several
minutes; subsequent local/CI runs reuse it while checking dependency changes.
These static checks do not start a worker and do not replace the example's tests
or real-worker qualification.
