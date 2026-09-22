# Low-level client

This unreleased checkout defaults to **smolvm 1.17.0** on Linux x86_64 and macOS
Apple Silicon; published SmolBox 0.1.5 still defaults to 1.16.1. Existing workers
can retain an explicit `runtime_version: "1.16.1"`. See the
[1.17.0 qualification](compatibility.md#smolvm-1-17-0-qualification).

This API performs one verified worker operation at a time. It does not persist
request identities, reserve capacity, reconcile a crash, or authorize deletion.
Use it when host code owns those responsibilities. For a complete managed
execution, begin with [Getting started](getting-started.md). This guide describes
the supported client contract and its development-qualified worker boundary.
See [runtime selection](compatibility.md#runtime-selection) for the explicit
Linux/macOS 1.16.1 default in SmolBox 0.1.5 and retained explicit 1.16.0,
1.14.6 and 1.14.1 compatibility. SmolBox 0.1.3 defaults to 1.16.0 and 0.1.2
to 1.14.6. Follow [Upgrading to 0.1.5](recovery.md#upgrading-to-0-1-5) when
updating an existing application.

Install the pinned smolvm release from [compatibility evidence](compatibility.md).
Prepare an approved, architecture-matched `.smolmachine` artifact on the worker
host, verify its digest, and start a private `smolvm serve` endpoint. For bounded
small-file workloads set `SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576` before starting
the server. SmolBox never enables guest networking to fetch an image.

For smolvm 1.14.6, 1.16.0, 1.16.1 and 1.17.0, verify the host's `resize2fs` before requesting disks smaller
than its bundled templates. Our macOS run without that tool lost a workspace
file after stop/start; health and successful execution alone did not detect the
problem. See [runtime prerequisites](compatibility.md#macos-1-14-6-prerequisites).

```elixir
{:ok, worker} = SmolBox.Worker.new("worker-1", "https://worker.internal.example",
  token: System.fetch_env!("WORKER_PROXY_TOKEN"),
  ca_cert_file: "/etc/my-app/worker-ca.pem")
{:ok, client} = SmolBox.Client.new(worker)
```

Remote workers require an authenticated TLS proxy. The operator supplies it;
SmolBox supplies no public worker service. TLS peer and hostname verification
cannot be disabled. Loopback development requires `allow_insecure_loopback: true`.
A local Unix socket can instead use `unix_socket: "/private/run/smolvm.sock"`
with `http://localhost`. Client construction makes no network request.

`Client.health(client)` reads the server-reported version, optional inventory
counts and uptime as a `SmolBox.Health` value. Missing counts remain `nil`; they
are not treated as zero. `Client.readiness(client)` requires the separate
blocking-pool probe to return HTTP 200 with an empty body. It preserves normal
authentication, TLS, deadline and byte-limit checks. JSON/SSE responses still
require their own media types. These endpoints do not attest artifact digests,
host quotas or isolation.

Creation replies must match the requested name, CPU count, guest memory, both
disk allocations and network policy. A mismatch returns a protocol error with uncertain
creation evidence. Managed execution does not start that guest or adopt it for
automatic cleanup; the original reservation remains available for operator
investigation. An erroneous worker reply must not silently change execution policy.

By default an owned disposable machine starts from an approved artifact with
guest networking disabled. Explicit outbound policies are described in
[Controlled network access](network-access.md). Mounts, sockets, GPU, ports and
workload restart remain disabled. This example uses the offline default:

```elixir
{:ok, name} = SmolBox.Identity.machine_name("myapp")
# Persist name and intent in your host before creating the machine.
{:ok, spec} = SmolBox.MachineSpec.new(name, "/approved/python.smolmachine",
  storage_gb: 20, overlay_gb: 10)
{:ok, created} = SmolBox.Client.create(client, spec)
# Persist creation evidence before continuing.
{:ok, running} = SmolBox.Client.start(client, name)
true = SmolBox.Machine.same_incarnation?(created, running)

source = "print('hello')\n"
:ok = SmolBox.Client.upload(client, name, "/workspace/main.py",
  source, SmolBox.Files.sha256(source))
{:ok, command} = SmolBox.Command.new(["python", "/workspace/main.py"], timeout_secs: 10)
{:ok, result} = SmolBox.Client.exec(client, name, command, max_output_bytes: 65_536)
```

The example shows the successful path. Production callers must handle each typed
error. A machine name or matching `createdAt` alone is insufficient ownership
proof after a conflict or manual replacement. Use an exclusive managed namespace,
save creation evidence, and refuse cleanup when identity differs. To preserve a
machine's disks, stop it and verify the same incarnation is no longer running.
For authorized disposal after collection and any required retention, delete the
verified owned machine and then inspect it to confirm absence. A failed stop
alone does not authorize disposal. No cleanup primitive should be placed in an
unconditional `after` block without checking identity and preserving uncertain
execution evidence first. The managed runtime's rules are described in
[preservation and disposal](recovery.md#preservation-and-disposal).

`exec/4` returns byte-exact stdout/stderr from upstream base64 fields. Nonzero exit
codes are observed results, not transport errors. `exec_stream/4` uses the actual
SSE protocol, captures bounded **lossy UTF-8**, and accepts `on_event: callback`.
Callbacks are synchronous, provide backpressure, and are bounded by the overall
operation timeout. A crashing optional callback is detached. Notifications are
advisory; they are not a durable event log. SmolBox rejects streaming stdin.
Use buffered execution or staged binary files instead.

Worker configuration separately bounds connection, pool checkout, receive idle,
overall operation, request bytes, and response bytes. The response cap includes
SSE framing and ignored events; exec also has an aggregate decoded stdout/stderr
cap. Req automatic retries, redirects, decompression, and body decoding are
disabled. Compressed responses are rejected. Limits on controller capture do not
replace upstream or worker-host limits.

A timeout, lost connection, malformed result, or output overflow after possible
dispatch returns uncertainty. **Never replay exec automatically.** Disconnecting
the stream does not cancel the guest. Stop an owned VM separately and verify its
state; stopping a VM does not recover an unknown command exit code.

## Checkpoint sources

An operator-approved idle checkpoint can be created with
`MachineSpec.new(name, path, source: :checkpoint, ...)`. The explicit allocations
must match the capture. This requires smolvm 1.16.1 or 1.17.0 and an offline source; creation
must return a created branchable machine before it may be started. Captured
processes resume on start, so a workload entrypoint override cannot neutralize
an arbitrary checkpoint. See [Executing from a checkpoint](checkpoints.md) for
approval, managed execution, examples and schema v3 upgrade requirements.

## Execution and transport budgets

`Command.new/2` accepts a guest timeout of 1–300 seconds. A managed command must
also fit its profile's `execution_ms`, whose maximum is 300,000 ms. Configure
the worker client's receive and total operation budgets separately: increasing
a guest deadline does not extend either HTTP budget. A quiet stream can reach
its receive timeout even while the guest continues working.

For example, a 120-second command can use `receive_timeout_ms: 130_000` and
`operation_timeout_ms: 150_000`, with a managed execution budget of at least
120,000 ms. These explicit client settings are within the existing limits; they
do not change the guest deadline. Allow for transport overhead and any separate
worker lifetime when selecting budgets for your own deployment.

A low-level exec can start a stopped VM before running the command. Its total
operation budget must allow for that startup as well as execution and response
collection. The command's 300-second maximum therefore does not bound the whole
client operation; `operation_timeout_ms` supplies that separate finite limit.

In smolvm 1.16.0, execution routes no longer inherit the generic five-minute
server timeout. That upstream change does not extend SmolBox's public command
maximum or remove its configured client deadlines. A buffered public exec
operation including implicit startup completed in 357.460 seconds, with a guest
command lasting 299.002 seconds. A streamed operation completed in 386.357
seconds, delivering its first output at 87.357 seconds and exit event at 386.357
seconds; its guest command lasted 299.000 seconds. These measurements include
startup and do not establish guest commands exceeding five minutes. See
[the qualification status](compatibility.md#smolvm-1-16-0-qualification) for the
retained startup failure and remaining acceptance work.
`SmolBox.await/3` has a separate caller wait budget. Expiring that wait does not
cancel the command or replace a recorded outcome with a timeout result.

## File operations

File manifests use exact `/workspace` paths and opaque host artifact references.
Low-level uploads accept at most 1 MiB, verify their source digest before I/O, and
validate the worker acknowledgment. Downloads have an explicit bound up to 1 MiB.
The pinned agent has an atomic file-install path, but the HTTP API offers no
caller-controlled rename transaction or permissions. Symlink handling also depends
on the agent's active guest namespace; lexical validation alone does not certify
race-free containment. No archives or recursive patterns are interpreted.

Both file endpoints can **auto-start a stopped machine**. Never download as a
harmless recovery probe or collect after confirmed termination. Keep stop/delete
as the final lifecycle operations for cancelled work. Host artifact credentials
must stay outside the guest, and host storage must protect command and environment
contents at rest.

## Preparing the reference runtimes

This is an operator step using upstream smolvm, outside the library's execution
API. It prepares a base language runtime; it does not build or publish user
functions. Perform it on an isolated preparation host with the matching native
architecture, sufficient disk/memory and the pinned installation. Preparation
may fetch images with networking; offline execution later must not.

From a new private directory with enough space for layers, templates and output,
the supported CLI provides these preparation commands:

```sh
smolvm pack create --image python:3.12-alpine --entrypoint /bin/true \
  --cpus 1 --mem 256 --staging-dir ./staging --output ./python
smolvm pack create --image node:22-alpine --entrypoint /bin/true \
  --cpus 1 --mem 256 --staging-dir ./staging --output ./node
```

The output names are executable stubs; the corresponding payloads are
`python.smolmachine` and `node.smolmachine`. Do not pass a `.smolmachine` extension
as `--output`, use `--single-file`, or reuse existing output names. SmolBox uses
the sidecar payload and does not invoke the packed executable. The CLI's default
pack memory is 8192 MiB, so the explicit resource options matter. Check local
`smolvm pack create -h` against the pinned version before changing the recipe.

These tags identify the initial test recipe, not immutable production approvals.
Select and record an approved OCI digest for repeatable preparation, then record
the resulting payload's SHA-256, host OS/architecture, upstream binary checksum
and template geometry. Use `shasum -a 256` on macOS or `sha256sum` on Linux to
hash each payload. A rebuilt artifact gets a new approved revision and new live
evidence even when its source image tag is unchanged.

Copy only the verified runtime payload into an operator-owned catalog on the
worker and verify the digest there. Inspect neutrality and keep secrets,
host mounts, ports and automatic workload restart out of the artifact/configuration.
Managed creation additionally forces `/bin/true`, empty command arguments and
restart `never`. Qualify offline Python/JS execution, binary staging/collection
and stop/start without replay before admitting the artifact. The real-runtime
tests exercise those behaviors; a pack operation alone does not qualify an image.

Choose the command's guest identity explicitly with `Command.new(argv, user:
"65534:65534")` when it matters, and verify the resulting UID and file access
with your artifact. SmolBox passes this choice to execution; it does not enforce
an application-wide guest user policy. Changes to upstream CLI `USER` handling
do not by themselves establish the same behavior through the HTTP API.

The released templates measured 20/10 GiB. Validate them and any larger artifact
templates before setting `allocation_floor`; do not infer physical disk capacity
from a smaller create request or initially sparse files. Keep preparation caches
under a separate host budget. See [resource qualification](resource-qualification.md).

Start a separately provisioned private worker with the tested file cap:

```sh
SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576 \
  smolvm serve start --listen 127.0.0.1:19470
```

This starts a local service, not an authenticated public endpoint. Configure
worker account isolation, hard host limits and the remote proxy independently
as described in [deployment boundaries](security.md). On Linux, an explicitly
configured `SMOLVM_DATA_DIR` can separate worker state. The pinned macOS build
uses its normal account state directory; that environment variable does not
isolate it. Use a dedicated account/host for a new macOS worker and never clear
shared caches or inventories to simulate a fresh installation.
