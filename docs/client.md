# Low-level client

This API performs one verified worker operation at a time. It does not persist
request identities, reserve capacity, reconcile a crash, or authorize deletion.
Use it only when host code owns those responsibilities. The managed runtime is
still under implementation.

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

An owned disposable machine starts from an approved artifact, with guest networking,
mounts, sockets, GPU, ports, and workload restart disabled:

```elixir
{:ok, name} = SmolBox.Identity.machine_name("myapp")
# Persist name and intent in your host before creating the machine.
{:ok, spec} = SmolBox.MachineSpec.new(name, "/approved/python.smolmachine")
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
advisory; they are not a durable event log. Streaming stdin is rejected because
SmolVM 1.14.1 ignores it. Use buffered execution or staged binary files instead.

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
