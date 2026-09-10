# Low-level client

This API performs one verified worker operation at a time. It does not persist
request identities, reserve capacity, reconcile a crash, or authorize deletion.
Use it when host code owns those responsibilities. For a complete managed
execution, begin with [Getting started](getting-started.md). This guide describes
the supported client contract and its development-qualified worker boundary.
See [runtime selection](compatibility.md#runtime-selection) for the explicit
Linux 1.14.6 candidate and retained 1.14.1 compatibility.

Install the pinned SmolVM release from [compatibility evidence](compatibility.md).
Prepare an approved, architecture-matched `.smolmachine` artifact on the worker
host, verify its digest, and start a private `smolvm serve` endpoint. For bounded
small-file workloads set `SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576` before starting
the server. SmolBox never enables guest networking to fetch an image.

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

Creation replies must match the requested name, CPU count, guest memory and both
disk allocations. A mismatched allocation returns a protocol error with uncertain
creation evidence. Managed execution does not start that guest or adopt it for
automatic cleanup; the original reservation remains available for operator
investigation. An erroneous worker reply must not silently change execution policy.

An owned disposable machine starts from an approved artifact, with guest networking,
mounts, sockets, GPU, ports, and workload restart disabled:

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
save creation evidence, and refuse cleanup when identity differs. After authorized
cleanup, verify a stopped state, delete the owned machine, then verify absence.
No cleanup primitive should be placed in an unconditional `after` block without
checking identity and preserving uncertain-execution evidence first.

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

This is an operator step using upstream SmolVM, outside the library's execution
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
