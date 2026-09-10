# Minimal host example

This Mix project runs SmolBox under a host supervisor with an explicitly
ephemeral memory store.
The shared example setup lives in `../support/lib`; keep that directory when
copying this example. Production consumers install the library separately.

Prepare a neutral Python `.smolmachine` artifact using the pinned SmolVM version
and start a private worker as described in `../../docs/client.md`. Run this
example on the worker host: it verifies the local artifact's SHA-256 before
configuring its approved catalog. It does not build or publish artifacts.
The worker must use the qualified file-transfer cap of 1 MiB.

Use the package's pinned Elixir/OTP toolchain. Create a private directory for
objects and a 32-byte fingerprint key from host secret storage, then set:

```sh
export SMOLBOX_RUNTIME_URL=http://127.0.0.1:19470
export SMOLBOX_RUNTIME_VERSION=1.14.6
export SMOLBOX_PYTHON_ARTIFACT=/absolute/path/python.smolmachine
export SMOLBOX_PYTHON_SHA256=the_verified_64_character_lowercase_digest
export SMOLBOX_ARTIFACT_ROOT=/absolute/private/directory/objects
export SMOLBOX_FINGERPRINT_KEY_FILE=/absolute/private/directory/fingerprint.key
export SMOLBOX_EXECUTION_ID=example-normal-001
MIX_ENV=test mix deps.get
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix dialyzer --force-check
MIX_ENV=test mix hex.audit
MIX_ENV=test mix deps.audit
MIX_ENV=test mix run scripts/demo.exs
```

The object directory must already exist with mode `0700`. Use the exact version
installed on the worker. The explicit 1.14.6 selection
is for Linux x86_64; use 1.14.1 on macOS. Omitting the variable retains 1.14.1.
The 0.1.2 compatibility candidate is not yet released. Keep key files private
and stable; the example does not print their contents. For an authenticated
HTTPS worker proxy, also configure `SMOLBOX_PROXY_TOKEN`; verified TLS remains
enabled. Unauthenticated HTTP is accepted only for explicitly allowed loopback.

Use `--force-check` for Dialyzer in these repository examples. SmolBox is a path
dependency whose code can change without changing the example lockfile; reusing
an unchecked PLT can otherwise retain obsolete dependency types.

The host stages a Python program and binary input, submits from a caller process
that then exits, submits the same identity again, verifies reversed binary output
and a one-byte test marker, and waits for deletion and reservation release. It
prints a bounded JSON record summary. The marker verifies this demonstration;
it is not a trusted execution receipt or an exactly-once mechanism.

For cancellation, use a new identity:

```sh
SMOLBOX_EXECUTION_ID=example-cancel-001 SMOLBOX_EXAMPLE_WAIT=true \
  MIX_ENV=test mix run scripts/demo.exs
```

The example waits for first output, persists cancellation, and waits through the
real unknown-result retention window before deletion. Expect roughly a minute,
not immediate completion. Cancellation cannot reconstruct the command's exit
status; a terminated VM can still have an unknown command result.

The default profile is explicitly a development profile. Guest CPU/memory
allocations are not hard host resource quotas, and upstream exposes no request
fencing primitive. This example does not certify hostile multi-tenant isolation.

Stopping this host loses its memory store. Use the durable host example for
restart recovery. Never run separate store authorities against the same physical
worker concurrently; even unique execution names do not coordinate capacity.

The shared setup uses immutable profile `example-offline-v2`: 1 vCPU, 256 MiB
guest memory, 768 MiB VMM allowance, 20 GiB storage and 10 GiB overlay. Its
required worker allocation floor matches the supplied 1.14.1 disk templates.
These are accounting reservations, not hard host filesystem/RSS quotas. A host
with different or larger artifact templates must requalify and update the floor.
Existing v1 records retain their original spec: inspect their original handles;
reusing their ID with the changed profile intentionally returns an identity conflict.
