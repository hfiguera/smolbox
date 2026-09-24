# Configurable guest paths and larger file transfers

SmolBox 0.2.0 lets an application stage project files, install home
configuration and collect larger artifacts without forcing everything beneath
`/workspace`. It adds explicit host-approved roots for uploads, downloads and
ordinary command working directories. Existing defaults remain `/workspace`,
1 MiB per file and 4 MiB per manifest direction.

Expanded policies require **smolvm 1.17.0 image machines**. Older workers and
checkpoints keep their existing contract. File bodies are buffered in the
controller and worker; this is a bounded larger-file API, not streaming bulk
storage. No recursive copy, globbing, archive extraction, resume, permission
selection or atomic multi-file snapshot is provided.

## Approve roots and budgets

The host chooses the policy, never an untrusted guest or caller. A changed profile
needs a new immutable revision ID. The client must approve a superset of the
profile's roots and at least its per-file budget. Both are rechecked when the
runtime uses the selected worker, including recovered staging and collection.

```elixir
alias SmolBox.{Client, Command, GuestPaths, Profile, Worker}
alias SmolBox.ArtifactStore.Directory

{:ok, paths} = GuestPaths.new(
  upload_roots: ["/app", "/home/dev/.config/smolbox"],
  download_roots: ["/app", "/home/dev/.config/smolbox"],
  workdir_roots: ["/app"])

{:ok, profile} = Profile.new("project-files-v1",
  guest_paths: paths,
  max_file_bytes: 16_777_216,
  max_total_file_bytes: 33_554_432,
  storage_gb: 2, overlay_gb: 2, host_overhead_mb: 768)

# Use these disk sizes only with a qualified 2/2 GiB artifact allocation floor.
{:ok, endpoint} = Worker.new("worker-1", "http://localhost",
  unix_socket: "/private/run/smolvm.sock",
  max_request_bytes: 16_777_216,
  max_response_bytes: 16_777_216,
  operation_timeout_ms: 90_000,
  receive_timeout_ms: 60_000)
{:ok, client} = Client.new(endpoint,
  guest_paths: paths, max_file_bytes: 16_777_216)

# Create this trusted private directory beforehand, with mode 0700.
{:ok, objects} = Directory.new("/private/smolbox/objects",
  max_file_bytes: 16_777_216)

{:ok, command} = Command.new(["python", "main.py"],
  workdir: "/app/project", timeout_secs: 10)
```

Register `profile` in the worker's `profiles` catalog, use `client` in its
`WorkerConfig`, and supply `{Directory, objects}` as the runtime artifact store.
Keep the existing verified artifact catalog, allocation floor, worker capacity and
store configuration; see [host integration](host-integration.md). Construction of
`Command` validates path syntax but does not itself authorize the directory.
The directory must exist before dispatch. Selecting a cwd does not create it;
upload staging can create missing parent directories upstream.

Roots match complete path segments: `/app` allows `/app/project`, not
`/application`. Each direction accepts at most 32 roots, sorted and deduplicated.
Empty upload/download lists deny that direction; working directories require at
least one root. Omitting a direction retains its `/workspace` default, so specify
all three when replacing defaults. An explicit `/` allows all syntactically valid
guest paths and deserves correspondingly broad host authorization. The root `/`
itself is not a file endpoint target.

Paths must be absolute UTF-8 strings of at most 1024 bytes without NUL, `%`,
backslashes, traversal (`.` or `..`), repeated separators or a trailing separator
(except root `/`). Spaces, Unicode and dotfiles are supported. Tildes and environment
variables are not expanded. Startup `Workload.workdir` and interactive PTY sessions
retain their separate contracts; this policy does not add a PTY cwd option.

## Stage, execute and collect

File manifests keep the existing shape and opaque host artifact references:

```elixir
source = "from pathlib import Path\nPath('result.txt').write_text('done')\n"
:ok = Directory.seed(objects, "team-1", "program-v1", source)

inputs = [%{
  "source" => "program-v1", "path" => "/app/project/main.py",
  "size" => byte_size(source), "sha256" => SmolBox.Files.sha256(source),
  "mode" => "runtime_default"
}]
outputs = [%{
  "destination" => "result", "path" => "/app/project/result.txt",
  "max_bytes" => 16_777_216
}]

{:ok, spec} = SmolBox.ExecutionSpec.new(
  scope: "team-1", id: "build-001", artifact: approved_artifact,
  profile: profile, command: command, inputs: inputs, outputs: outputs)
{:ok, execution} = SmolBox.Machines.submit(runtime, machine_handle, spec)
{:ok, %{state: :completed}} = SmolBox.await(runtime, execution, 120_000)
{:ok, bytes} = Directory.read_output(objects, execution, "result", 16_777_216)
```

`machine_handle` must refer to a machine created with the same profile and
artifact; `runtime` is the configured runtime and `approved_artifact` is its
catalog identity. For disposable execution, use `SmolBox.submit(runtime, spec)`.
The runnable example below supplies the complete setup. Production callers must
handle typed errors, nonzero exit codes and uncertain outcomes explicitly.

Every input requires **both upload and download approval**: staging verifies
size and SHA-256 before upload, checks the acknowledgment, then downloads and
verifies the bytes before command dispatch. Outputs require download approval.
Per-direction manifests allow at most 32 unique paths/references. The sum of
input sizes and, separately, declared output maxima must fit the aggregate budget.

Low-level operations use the same client policy:

```elixir
:ok = Client.upload(client, owned_name, "/app/data.bin", data,
  SmolBox.Files.sha256(data))
{:ok, returned} = Client.download(client, owned_name, "/app/data.bin", 16_777_216)
```

The low-level caller owns machine identity checks and serialization. Managed
commands retain their existing single active slot through staging and collection,
so stop/delete cannot race that work through the managed API. Already launched
background processes and startup workloads may still change files; neither
readback nor collection is an atomic filesystem snapshot.

## Coordinate limits

| Layer | Default | Explicit supported maximum |
| --- | --- | --- |
| Profile, per file | 1 MiB | 16 MiB |
| Profile, each manifest direction | 4 MiB | 64 MiB |
| Client file allowance | 1 MiB | 16 MiB |
| Worker transport request body | 1 MiB | 16 MiB |
| Worker transport response body | 16 MiB | 32 MiB; file allowance still caps at 16 MiB |
| Directory artifact adapter, per file | 1 MiB | 16 MiB |

The aggregate profile budget must cover its per-file budget. Extended profiles
require request and response caps at least as large as `max_file_bytes`, even
when a particular command has no files. Configure external artifact adapters to
honor the same read bounds and support the approved file size; arbitrary adapter
capabilities cannot be inferred by the runtime.

Start the private worker with an independently approved download cap, for example:

```sh
SMOLVM_FILE_TRANSFER_MAX_BYTES=16777216 smolvm serve start --listen unix:///private/run/smolvm.sock
```

On the qualified upstream version, this setting bounds agent reads/downloads;
it does **not** reduce the HTTP upload body ceiling of 100 MiB. SmolBox caps its
own uploads at 16 MiB. Bound direct worker access and host memory separately.
Upstream buffers whole HTTP bodies even though its internal agent protocol uses
chunks. Expect multiple in-memory copies during digest/readback/artifact handling.
The 16 MiB ceiling is a deliberate library bound for this implementation, not an
upstream file-size maximum or a total RSS guarantee. Raise preparation, collection,
receive-idle and overall operation budgets only as required by measured transfers.

## Recovery and upgrades

Explicit `Profile.guest_paths` (even an explicit default policy), per-file budgets
over 1 MiB, or aggregate budgets over the old 16 MiB ceiling select **codec v9**.
These records require store capability `guest_files: 1`. Memory and the durable
PostgreSQL example implement it. No SQL migration is needed.

Upgrade every controller, reader and adapter sharing the store before enabling
v9 writes. Existing v1–v8 records load with `guest_paths: nil`, preserve their
fingerprints, and keep prior encodings when no new file policy is used. Old schema
envelopes cannot smuggle broader cwd or file budgets. V9 also preserves other
record features such as ports, background intent, PTY intent and startup workloads;
their existing store capabilities remain required.

Policies and byte budgets are immutable request identity. Identical duplicate
submissions retain their handle; changed roots, limits or cwd conflict under the
same scoped ID. Deleted tombstones retain the policy and history. Rollback to a
reader without v9 support is unsafe while v9 records or tombstones remain; do not
strip policy/history to make them appear old. Plan a coordinated backup/restore
with worker reconciliation if a deployment rollback is required.

On recovery, a revoked worker profile or insufficient client policy prevents file
I/O. Restore the exact approved configuration or use the existing explicit
resolution/cleanup workflow; recovery never silently broadens permissions.
Transfer failures do not authorize command replay. A timeout, interrupted upload
or lost acknowledgment can leave a partially changed guest; the low-level client
never retries automatically. Managed preparation verifies files before executing,
and resumed preparation may restage immutable inputs before dispatch. Unknown
commands remain blocked without replay. Collection failure retains known command
results and reports failed/partial collection separately.

Uploads and downloads can **start a stopped VM**, including its startup workload.
Do not use them as passive recovery probes or as post-cancellation collection.
Caller disappearance or wait timeout does not stop the operation. Cancellation
and lifecycle uncertainty retain the existing [recovery rules](recovery.md),
including the fact that observed stop does not fence already-sent requests.

## Filesystem boundary

Roots authorize lexical API paths; they are **not a symlink sandbox**. A permitted
guest path may be a symlink to another guest directory. Qualification on the
prepared Python artifact reads a guest-only `/tmp` sentinel through a permitted
symlink; upload replaces the link without modifying its former target. A guest
`stat` before transfer cannot remove this race. Arbitrary guest commands can read
or write outside their cwd roots as allowed by guest permissions. Keep secrets
out of the entire guest, not merely outside the approved roots.

The existing FIFO limitation also applies: upstream may open before checking for
a regular file, so a read can block. A client deadline bounds observation, not
worker termination. Host artifact paths remain opaque, hashed and independent
from guest paths. See [security](security.md) for these boundaries.

## Runnable acceptance scenario

Follow the PostgreSQL and private worker setup in
[the durable example](../examples/durable_host/README.md), using the 16 MiB worker
read cap above and an approved image with a verified 2/2 GiB allocation floor.
From `examples/durable_host`, keep the same private object root, keys and partition:

```sh
export SMOLBOX_EXECUTION_ID=guest-files-example-1
export SMOLBOX_STORE_PARTITION=guest-files-example-1
mix run scripts/guest_files.exs prepare
mix run scripts/guest_files.exs resume
```

`prepare` creates a machine, stages a 16 MiB binary under `/app/project` and a home
configuration file, executes with that cwd, and collects/verifies the binary.
`resume` starts a fresh BEAM controller against PostgreSQL, reconnects to the same
machine and policy, reads the files, stops/starts, reads again, then explicitly
deletes and verifies absence and released reservations. The `delete` phase is
available for explicit cleanup of an interrupted demonstration. Test coverage and
real-worker receipts are in [validation](guest-files-validation.md).
