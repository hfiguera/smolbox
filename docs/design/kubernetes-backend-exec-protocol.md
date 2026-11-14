# Kubernetes preview command protocol

Status: transport component implemented; the Phase 4 guarded adapter live gate
remains open. See [progress](kubernetes-backend-progress.md) and the
[delivery plan](kubernetes-backend-implementation-plan.md). No public managed
Kubernetes execution is enabled by this component qualification.

## Control boundary

The API request names the assigned Pod and the `workload` container, with stdin,
stdout and stderr enabled and TTY disabled. The repeated `command` query parameters
contain only `python3 -I -S -u -c` and the fixed packaged helper source. Application
argv, environment and workdir never enter the URL. Credentials remain in the
Authorization header and outside persisted execution authority.

The client requires `v5.channel.k8s.io` with no extensions, renegotiation or
fallback. Binary messages begin with a channel byte: 0 stdin, 1 stdout, 2 stderr,
3 Kubernetes terminal Status. Channel 255 is the v5 stream-close control and is
validated independently. Ping/pong and fragmented messages are bounded before
assembly. Kubernetes status and controls never become workload stderr.

See the pinned upstream [channel constants](https://raw.githubusercontent.com/kubernetes/apimachinery/v0.35.0/pkg/util/remotecommand/constants.go)
and [exit-status decoder](https://raw.githubusercontent.com/kubernetes/client-go/v0.35.0/tools/remotecommand/v4.go).

## SBK1 command framing

The helper receives one request on channel 0:

| Bytes | Meaning |
| --- | --- |
| 0–3 | ASCII `SBK1` |
| 4–7 | Unsigned big-endian JSON byte length, 1 through 1,048,576 |
| Next declared bytes | UTF-8 JSON control object |

The exact object keys are `version: 1`, `operation: "exec"`, `argv`, `env`,
`workdir`, and `data_bytes: 0`. `argv` is a list of strings; `env` is a list of
two-element name/value lists, preserving the approved command representation.
The helper rejects duplicate JSON keys, excessive nesting, invalid types,
duplicate environment names, NULs, unsupported paths and declared excess data.
The same command bounds are checked on the host before opening the stream.
Public stdin, guest user overrides, background commands and terminals remain
unsupported. File operations will require separately qualified schemas.

The helper reads exact lengths in bounded chunks. EOF is never a delimiter. The
client keeps its stdin producer open until command completion; it does not send
stdin-close before dispatch. This is necessary for the qualified runtime's
CloseIO/FIFO behavior. Already queued excess input fails validation. The trusted
host producer sends no bytes after the declared control object.

After validation and changing directory, the helper writes the eight-byte
acknowledgement `SBK1` followed by four zero bytes to stdout. The transport strips
this prefix across message boundaries. It buffers bounded stderr until the
acknowledgement, so helper validation diagnostics cannot enter application
callbacks. Validation failure exits 126 without acknowledging; it cannot qualify
a workload result. The helper replaces fd 0 with `/dev/null` and directly calls
`execvpe`; it does not invoke a shell. Failure to execute the approved program
after acknowledgement exits 127 with a constant diagnostic.

## Results, bounds and uncertainty

Only an acknowledged helper plus an actual terminal Status can qualify an exit.
Success maps to 0; NonZeroExitCode must contain one valid decimal ExitCode cause
in 1–255. Empty, malformed, duplicate-key, duplicate or conflicting status does
not qualify successful completion. A normal WebSocket close is also required.
An interrupted/proxy close preserves an already observed exit as partial evidence.
No missing exit is synthesized from a connection close or helper output.

Stdout/stderr retain exact bytes with a combined output cap. Status has a separate
8-KiB cap; wire frames, message reassembly, aggregate response bytes and handshake
headers are independently bounded. Input is sent in 16-KiB chunks while output
and control messages are drained. One monotonic deadline includes credentials,
TLS, pre/postflight observations, input, callbacks and output. Synchronous
callbacks provide backpressure; they cannot create an unbounded event queue.

The socket belongs to an isolated operation process. Deadline or caller death
kills that observer and closes the socket. This does not attest termination of
the application. An observed exit and bounded partial result survive an observer
failure. Without such an exit, the error remains uncertain and has no fabricated
Result. A pre-upgrade credential/TLS failure or explicit 401/403 is definitive
before application dispatch. No failure triggers automatic exec replay.

## Required ownership evidence

Assigned exec accepts only the exact saved command, ready receipt and original
Pod name. It checks enrollment, Pod UID, effective template, zero restarts and
container/image identity before and after I/O. Fresh node evidence must match
the saved sandbox, KVM PID births, executable, bridge interfaces and observer
epoch, with complete history and effective isolation. Unit fake providers only
test the guard; they cannot enable or qualify real application execution.

The exec API is addressed by name and has no atomic UID precondition. Pre/post
checks cannot eliminate the intervening replacement race. The preview requires
an exclusive namespace, one controller/slot, opaque assigned names and no name
reuse. A replacement or evidence gap fails closed; it is never adopted or retried.
UID-bound deletion and positive physical cleanup remain required separately.

## Manual checks

Run the focused Elixir Kubernetes exec/remote-command tests and existing terminal
transport tests with `mix test`, and the local helper suite with
`python3 -m unittest discover -s scripts/kubernetes -p 'test_*.py'`.
The helper source is an explicit Hex package asset and compile-time input, then
embedded in the BEAM. The manual package-consumer command in
[the maintainer guide](../../scripts/ci/README.md) checks a fresh production build
with its own build path; compiling an already built checkout is insufficient.
Live checks use the disposable lab and stay outside CI workflows.
