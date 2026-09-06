# Compatibility evidence

Status: qualification in progress, 2026-09-06. No production profile is certified.

## Pinned upstream

- SmolVM `v1.14.1`, commit `e8d09ef616d363004d55b80a6cdb31a4e7e1842d`.
- macOS arm64 release archive SHA-256:
  `27f2ae7057f235a67a58fd13d0657c268cf9a16f214f8b177427d29daab0ae2f`.
- Linux x86_64 release archive SHA-256:
  `e91786c12808ce87655aa190eb5f6692672cd659a89367b5ec18dace5756af2f`.
- Exported OpenAPI SHA-256:
  `9ccc9eace040b1b44031f1abf9126496d750e8b2ba5bcaa734e7d62bade67bbe`.

Archives were downloaded from the [upstream release](https://github.com/smol-machines/smolvm/releases/tag/v1.14.1)
and matched the release API digests. Source was inspected through read-only Git
objects because the provided checkout was incomplete during the initial audit.

## Initial host observations

macOS arm64: Darwin 25.6.0; official binary starts and serves health/version.
A prepared Python artifact successfully created, started, and executed a Python
command with `network: false`, no mounts/ports, and restart policy `never`.
This is initial evidence, not the completed platform suite.

Linux x86_64: `ssh linux`, kernel `7.1.5-76070105-generic`, readable/writable KVM,
8 logical CPUs, approximately 64 GiB RAM. Official binary starts and serves
health/version. Both platforms pass the initial Python/Node smoke probe below.

The Linux runtime uses `/tmp/smolbox-qualification/data` as a dedicated data root.
Its login shell initially had no Elixir, Mix, or SmolVM on PATH; the pinned
SmolVM distribution was extracted in `/tmp/smolbox-qualification/runtime`.
Elixir 1.20.4 / OTP 28.5 was installed under `/tmp/smolbox-qualification/mise`
for library tests, without changing the account's global toolchain.
macOS uses unique test machine
names in the normal SmolVM state directory: `SMOLVM_DATA_DIR` is Linux-only in
this release. Never delete machines belonging to another workload.

### Reproducible initial smoke probe

The maintained `scripts/qualify_runtime.py` explicitly contacts a loopback
worker. It is separate from `mix ci`. Use the pinned distribution to prepare
Python and Node artifacts on each matching host, then start `smolvm serve start
-l 127.0.0.1:19470` with `SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576`.
Preparation may fetch approved public images; execution itself uses no guest
network. Initial artifacts were built from `python:3.12-alpine` and
`node:22-alpine`, overriding the entrypoint to `/bin/true` with restart `never`.
Those tags are preparation inputs only; each probe records the actual artifact
SHA-256. Rebuilt artifacts require new evidence.

```sh
python3 scripts/qualify_runtime.py \
  --python /tmp/smolbox-qualification/python.smolmachine \
  --node /tmp/smolbox-qualification/node.smolmachine \
  --report /tmp/smolbox-qualification/smoke.json
```

Reports: [macOS](evidence/phase0-macos.json), [Linux](evidence/phase0-linux.json).
Both demonstrate create/start with no mounts, ports, or guest network; binary
file round trips; byte-exact buffered output with a nonzero exit; an observed
one-second command timeout; text SSE and exit; failed public TCP egress; and
stop/delete. Timings include intentional timeout tests, not performance benchmarks.
These probes do not prove child-process termination, connection-loss recovery,
control-plane isolation, hard host quotas, or managed-library behavior.

## Source-derived contract findings

These findings require continued real-runtime verification:

- Buffered exec carries `stdoutB64` and `stderrB64`; use those for byte accuracy.
- SSE stdout/stderr contain plain lossy UTF-8 text, not JSON-encoded bytes.
  SSE exit data is JSON with `exitCode`. Never label text streams byte-exact.
- The SSE handler ignores `stdin`; reject supplied stdin on the streaming path.
- Streaming relay has an 11 MiB aggregate cap plus one received frame. The
  channel is unbounded by count, so limits on controller capture do not replace
  upstream/host memory accounting or frame-bound verification.
- File download buffers server-side. Configure `SMOLVM_FILE_TRANSFER_MAX_BYTES`
  on workers; the default 4 GiB is unsuitable for small-file profiles.
- File transfer into image machines invokes an internal `/bin/true` command to
  activate the overlay. This is not the user command and must not become one.
- Exec has no verified durable request receipt or deduplication ID. Lost
  acceptance/result evidence remains unknown; never automatically replay exec.
- Machine identity includes `createdAt` at second resolution, not a verified
  immutable generation token. Namespace exclusivity is an operator requirement;
  a matching name alone cannot authorize deletion after a conflict.

## Qualification still required

| Control | Linux x86_64 | macOS arm64 |
|---|---|---|
| Guest vCPU/memory allocation | Initial allocation only | Initial allocation only |
| Host RSS / CPU-time hard quota | Uncertified | Uncertified |
| Guest disk and host storage accounting | Pending | Pending |
| Hostile process count control | Uncertified | Uncertified |
| Deadline and whole-VM termination | Pending | Pending |
| Output and file transfer caps | Source evidence; binary round trip passes | Source evidence; binary round trip passes |
| No guest egress / control-plane access | Public TCP denial passes; broader checks pending | Public TCP denial passes; broader checks pending |
| Durable result recovery | No verified receipt | No verified receipt |
| Safe cancellation and cleanup | Normal stop/delete passes; races pending | Normal stop/delete passes; races pending |
| Authenticated remote API | Pending | Pending |

Uncertified hard controls must be rejected before dispatch. Local development
qualification must not be advertised as production multi-tenant certification.

## Toolchain

Canonical: Elixir 1.20.4 / OTP 28.5. Minimum lane: Elixir 1.18.4 / OTP 27.3.4.15.
Additional lane: Elixir 1.19.5 / OTP 28.5. Scaffold compilation/tests pass on
all three combinations in separate local workspaces. The canonical `mix ci`
also passes on the Linux host. These results cover the scaffold, not the future
managed runtime. Repository pins do not change the user's global toolchain.

Use separate workspaces for simultaneous Elixir/OTP lanes. Sharing dependency
directories can mix rebar build artifacts. Source transfers to Linux must omit
macOS resource-fork/AppleDouble metadata; otherwise `._*.exs` files are invalid
Elixir inputs. The recorded successful Linux run used a plain source archive.

Credence 0.8.1 emits upstream compilation warnings on Elixir 1.20.4; Mix's
dependency compilation reports them separately from the project's warning gate.
They are not suppressed or represented as SmolBox diagnostics. The library and
developer tasks pass warning-as-error compilation. No dependency source was patched.

The repository currently has no configured Git remote. Source metadata and an
independent consumer review remain release prerequisites, not fabricated links
or evidence supplied by these examples.
