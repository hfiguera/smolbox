# Workloads and console diagnostics

Managed image machines on smolvm **1.17.0** can start an application whenever the
VM starts. Startup configuration belongs to the machine's immutable creation
specification. Commands and terminal sessions remain separate executions.

This feature exposes **console diagnostics**, not application stdout/stderr.
Upstream 1.17.0 sends the detached startup container's standard streams to
`/dev/null`. Its restart supervisor observes VM liveness and does not relaunch the
container after restarting the VM. SmolBox therefore accepts only
`restart: :never`; automatic policies fail before dispatch.

## Configure a machine

```elixir
{:ok, workload} = SmolBox.Workload.new(
  entrypoint: ["python"],
  cmd: ["-m", "http.server", "8000", "--bind", "0.0.0.0"],
  env: [{"APP_MODE", "development"}],
  workdir: "/app",
  restart: :never
)

{:ok, spec} = SmolBox.ManagedMachineSpec.new(
  scope: "project-a",
  id: "web-v1",
  artifact: approved_artifact,
  profile: approved_profile,
  workload: workload,
  ports: [%SmolBox.PortMapping{host: 18080, guest: 8000}]
)
{:ok, handle} = SmolBox.Machines.create(runtime, spec)
{:ok, %{state: :created} = record} = SmolBox.Machines.await(runtime, handle, 90_000)
{:ok, _} = SmolBox.Machines.start(runtime, handle, record.version)
{:ok, %{state: :running}} = SmolBox.Machines.await(runtime, handle, 90_000)
```

The approved image must contain `/app` and the application dependencies. Configure
[port mappings](port-mappings.md) and outbound networking independently. The host
must authorize workload code, environment, artifact, profile and scope; a machine
handle is not an access token. Low-level callers can supply the same `workload`
option to `SmolBox.MachineSpec.new/3` and use `SmolBox.Client.create/2`.

- Omitting `workload` preserves the existing `/bin/true` startup behavior.
- `Workload.new()` with both argument arrays empty explicitly inherits the image's
  entrypoint and command. If either array is nonempty, **both arrays replace the
  image defaults**, then concatenate. There is no implicit shell.
- Environment pairs override image values. Duplicate names are rejected; order
  does not change managed identity. Arguments and environment follow `Command`
  bounds; startup arguments allow up to 255 elements in total.
- `workdir: nil` inherits the image directory. Explicit directories must be
  absolute, valid UTF-8, NUL-free and at most 4096 bytes. Existence is a guest
  concern and cannot be checked at construction.
- `:always`, `:on_failure`, `:unless_stopped`, retry limits and other automatic
  restart configurations are unsupported. Checkpoints cannot add a workload.

Identical create requests deduplicate. Changed arguments, environment, directory
or workload presence conflict under the same scoped ID; use a new machine ID.
The durable spec preserves intent across controller restarts. Upstream machine
observations do not attest workload fields, application health or exit status.
The existing recorded-incarnation checks and exclusive worker namespace remain
required; never adopt a machine by its name alone.

## Startup, retention and failure

A running VM does **not** prove the application started successfully. Upstream
startup is best effort and can return success even when launch fails. Use an
application-specific readiness check, such as an HTTP endpoint or a known file.
A workload may exit while the VM still reports running. SmolBox does not replay,
restart, supervise, or produce an execution result for the startup process.

Explicit stop/start launches the workload again and preserves persistent files.
Starting an already-running VM does not imply a fresh application launch. Some
upstream exec and file operations also boot a stopped VM and launch its workload;
prepare initial application files in the approved artifact. File staging before
startup is not an atomic deployment mechanism.

The machine, disks and reservations remain until explicit deletion. Startup work
shares the machine's resources with commands and terminals. The one-active-command
rule governs submitted executions, not the startup process. Command failure,
cancellation or caller disappearance does not delete the machine or stop its
workload. Stop/delete retain their existing active/unknown-command guards.

## Read console diagnostics

```elixir
{:ok, %SmolBox.LogResult{source: :console, lines: lines}} =
  SmolBox.Machines.logs(runtime, handle, tail: 100)

# Run this in a host-supervised task when following should not block the caller.
SmolBox.Machines.logs(runtime, handle,
  tail: 20,
  follow: true,
  timeout_ms: 30_000,
  max_output_bytes: 1_048_576,
  on_event: fn {:log, line} -> IO.puts(line) end
)
```

`SmolBox.Client.logs(client, machine_name, options)` provides the low-level form.
The managed form first reads the store and checks the remote incarnation. It
never starts, stops, deletes or reconciles the machine. It takes no command slot,
so it can run during commands and does not block stop/delete. Missing logs (404)
do not prove the machine is absent. Store/worker errors fail the observation
without releasing capacity or changing durable intent.

Snapshots return typed console lines on complete EOF. Following requires an
`on_event` callback; it receives complete SSE `{:log, line}` events synchronously
with backpressure. Upstream may combine lines in one event; strings are lossy
UTF-8, not binary-preserving output. Unknown event types and keepalives are ignored.
A callback that raises or throws is detached; capture continues. Do not send an
unbounded stream into another process's mailbox from the callback.

`tail` is 0–10,000 (default 100); 0 skips existing lines. `follow` defaults to
false. `timeout_ms` is 1,000–300,000 (default 30,000), capped by the configured
worker operation budget. The client's health preflight shares that budget.
Managed identity inspection has its own worker request budget. `max_output_bytes`
is 1–8,388,608 (default 1,048,576), counting one newline per event; capture also
stops after 10,000 events. Worker wire-byte, frame and receive limits still apply,
including ignored frames. A slow callback cannot extend the operation deadline.

Following ends on server EOF, an error, timeout, output limit or termination of
the owning task. Timeout returns an error; already delivered callback events
remain observed, but no partial `LogResult` is returned. There is no automatic
reconnection, durable cursor, replay guarantee or persisted transcript. A new
follow request can miss or duplicate lines. Upstream read-error strings are
ordinary console text and cannot reliably be distinguished from log content.
Console diagnostics may include complete startup arguments and working directories.
Protect them even when application stdout is unavailable.
Use these logs for boot/agent context; some launch errors exist only in the
worker's host logs. Configure the application to write its own files if application
diagnostics are required, and retrieve those through authorized execution/file
operations. Do not present console lines as application logs or readiness proof.

## Persistence and upgrades

Workload machines selectively write **codec v8** and require store capability
`managed_workloads: 1`. Memory and the PostgreSQL example implement it. Existing
v4/v5/v6 machines load with `workload: nil`; records without a workload retain
their prior encoding and fingerprints. Old envelopes reject workload semantics.
Execution records keep their existing formats, including commands on workload
machines. There is no new SQL migration; apply all existing migrations first.

Upgrade every controller, reader and adapter sharing the store and workers before
enabling workloads. Capability advertisement asserts v8 preservation through
acceptance, claims, lifecycle changes and tombstones. Custom transports must
support the new `{:logs, max_output_bytes, callback}` request mode and typed
`LogResult`; do not enable log reads on adapters that lack that contract.

Workload arguments and environment are durable sensitive data, including after
deletion. Inspect output is redacted, but encoding is not encryption; encrypt and
authenticate persisted records and protect log callbacks, backups and exports.
No automatic transcript or machine expiry is added. Rollback to an older reader
is unsafe while any v8 record or tombstone remains; do not strip workload intent
or delete history to make rollback appear safe. Restore a coordinated compatible
backup only under an explicit recovery plan, with worker reconciliation.

## Runnable durable example

Use the environment and PostgreSQL setup in the
[durable host example](https://github.com/hfiguera/smolbox/tree/main/examples/durable_host).
With an approved Python image and a qualified `resize2fs` worker:

```sh
cd examples/durable_host
export SMOLBOX_EXECUTION_ID=workload-example-1
export SMOLBOX_STORE_PARTITION=workload-example-1
mix run scripts/workload.exs prepare
mix run scripts/workload.exs resume
```

`prepare` starts Python with explicit arguments, environment and directory,
verifies a durable startup marker using a separate command, samples console logs
and follows them with a one-second bound. It retains the running machine.
`resume` uses a fresh controller process, verifies no extra startup occurred,
stop/starts the same machine, verifies a second startup and preserved files,
then deletes it and checks absence and released reservations. After a failed
example, inspect evidence before deciding recovery; `delete` is an explicit
cleanup phase. See [validation](workloads-validation.md) for real-worker evidence.
