# Kubernetes preview file protocol

Status: assigned backend Phase 5 qualified, November 13, 2026. Public managed
admission remains disabled pending Phases 6–7. See [progress](kubernetes-backend-progress.md)
and [live evidence](../evidence/kubernetes-backend-phase5-2026-11-13.json).
This is the narrow workspace contract, not general guest filesystem support.

## Transport and authority

Upload/download reuse the bounded `v5.channel.k8s.io` exchange, verified TLS,
separate binary channels, actual Kubernetes exit status and normal close. Before
and after a successful exchange the backend checks the saved Pod UID, container,
image, original sandbox/PID birth, observer epoch, complete history and fresh
network isolation. A failed guard never authorizes a transfer. No file request
retries an uncertain upload or re-executes an application to recover output.

The exec URL contains only a fixed Python loader. Channel 0 carries:

```text
SBP1 | u32 helper source length | fixed digest-approved helper source
SBK1 | u32 JSON control length  | exact control JSON | declared raw input
```

The loader verifies the compiled size/digest, writes a Linux memfd, applies
WRITE/GROW/SHRINK/SEAL seals and execs Python against that descriptor. It never
evaluates application strings or creates a writable script. The helper closes
the source descriptor before application execution. The producer stays open
until completion: EOF and Kubernetes stream-close are not delimiters because
the qualified shim has a CloseIO/FIFO race. Application stdin stays `/dev/null`.

Control JSON has exact keys: `version: 1`, `operation`, `path`, `data_bytes`,
`timeout_ms`, plus `sha256` for upload or `max_bytes` for download. Duplicate keys,
unknown fields, wrong types, deep JSON, short frames and already pending excess
input fail. The control header is at most 1 MiB and fixed source at most 64 KiB;
aggregate operation request/response budgets account for source, framing, API,
node callbacks and transport. The file utility has its own bounded alarm as well
as the controller's monotonic operation/stage deadline.

## File safety and framing

Paths must be UTF-8, at most 1,024 bytes, below `/workspace`, with at most 64
components of at most 255 bytes. Empty, dot/dot-dot, percent, backslash and NUL
components are rejected. Directory descriptor walks use no-follow semantics and
check held ancestor identity. Upload may create directories; download does not.
Regular, single-link files are required; symlinks, directories, FIFO and hard
links are rejected. These checks do not establish adversarial guest isolation.

An upload must match a declared input path, byte count and SHA-256 before upgrade.
It is allowed only before application dispatch. The utility reads at most 1 MiB,
hashes exact bytes into an exclusive random temporary file in the target
parent, fsyncs, checks the original target and ancestors, atomically replaces the
target, then fsyncs the directory. It acknowledges only after that commit. On a
known pre-commit failure it removes only its own temporary inode. An interruption
after rename but before acknowledgement stays uncertain; Pod disposal resolves
that work without retrying the upload or application.

Download is allowed for declared input read-back before dispatch, or declared
outputs during collection after a persisted actual application exit. The requested
maximum cannot exceed the profile or declared output bound. The utility opens
with no-follow/nonblocking flags, checks type/link count/size before reading,
then snapshots at most 1 MiB. It rejects short/excess data, changes in inode,
size, mode, links, mtime or ctime, replacement of the path, and changed ancestors.
Only a completely checked snapshot becomes a reply.

Successful utility stdout is:

```text
SBK1 | u32 zero
SBF1 | u32 JSON header length (1..8192) | exact metadata JSON | raw data
```

Metadata has exactly `version: 1`, `operation`, `path`, `size`, `sha256`. Upload
has no reply body; download has exactly `size` bytes with the matching SHA-256.
Empty files explicitly use size zero and the SHA-256 of empty bytes. The host
rejects duplicate fields, extra bytes, incorrect metadata, truncation, nonempty
utility stderr, missing acknowledgement/status and invalid close. Raw file bytes
are never decoded as text. Utility rejection exit 126 is retained as utility
error evidence; it never overwrites the saved application's result or becomes
an application result.

## Shared runtime and manual validation

`Runtime.Files` retains its upload/read-back and ArtifactStore rules. Kubernetes
connections share the remaining preparation/collection deadline with the
callback; callback expiry or invalid bytes cannot produce a success receipt.
Original nonzero command exits survive collection failures. Aggregate manifest
limits remain enforced independently of individual transfer caps.

Run local deterministic checks manually:

```sh
mix test test/unit/kubernetes_files_test.exs test/unit/kubernetes_runtime_files_test.exs test/unit/kubernetes_exec_test.exs --warnings-as-errors
python3 -m unittest discover -s scripts/kubernetes -p 'test_*.py'
mix format --check-formatted
```

The real Phase 5 component campaign used the enrolled disposable K3s lab and real
assigned backend/shared Runtime.Files. Its successful case additionally checked
UID deletion, original CRI absence, typed node proof and guarded Memory store
release. Its unsafe-output case required a later cleanup observation after a
CRI absence timeout and does not claim store release. These manual component
checks do not qualify managed-controller restart, durable recovery or public
admission. Those remain Phases 6–7; do not add these lab checks to CI.
