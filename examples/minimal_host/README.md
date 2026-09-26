# Minimal host example

SmolBox 0.2.1 defaults to smolvm **1.19.0**; 0.2.0 retains 1.17.0.
See [Upgrading to 0.2.1](../../docs/upgrading-to-0.2.1.md) before updating an existing worker configuration.
Follow [the coordinated upgrade guide](../../docs/upgrading-to-0.2.0.md) before
using new features against an existing store.
Set `SMOLBOX_RUNTIME_VERSION=1.16.1` explicitly for an existing 1.16.1 worker.
See [qualification](../../docs/runtime-1.19.0-qualification.md).

This example keeps the image-based path simple. For approved idle checkpoint
execution with PostgreSQL and recovery across application processes, see the
[durable checkpoint example](../durable_host/README.md#checkpoint-execution-and-recovery).
Checkpoint support requires SmolBox 0.1.5 or later.

This Mix project runs SmolBox under a host supervisor with an explicitly
ephemeral memory store.
The shared example setup lives in `../support/lib`; keep that directory when
copying this example. Production consumers install the library separately.

Prepare a neutral Python `.smolmachine` artifact using the pinned smolvm version
and start a private worker as described in `../../docs/client.md`. Run this
example on the worker host: it verifies the local artifact's SHA-256 before
configuring its approved catalog. It does not build or publish artifacts.
The worker must use the qualified file-transfer cap of 1 MiB.

Use the package's pinned Elixir/OTP toolchain. Create a private directory for
objects and a 32-byte fingerprint key from host secret storage, then set:

```sh
export SMOLBOX_RUNTIME_URL=http://127.0.0.1:19470
export SMOLBOX_RUNTIME_VERSION=1.19.0
export SMOLBOX_PYTHON_ARTIFACT=/absolute/path/python.smolmachine
export SMOLBOX_PYTHON_SHA256=the_verified_64_character_lowercase_digest
export SMOLBOX_ARTIFACT_ROOT=/absolute/private/directory/objects
export SMOLBOX_FINGERPRINT_KEY_FILE=/absolute/private/directory/fingerprint.key
export SMOLBOX_EXECUTION_ID=example-normal-001
MIX_ENV=test mix deps.get
mix quality
MIX_ENV=test mix hex.audit
MIX_ENV=test mix deps.audit
MIX_ENV=test mix run scripts/demo.exs
```

The object directory must already exist with mode `0700`. Use the exact version
installed on the worker. Version 1.19.0 is the default on Linux x86_64 and macOS
Apple Silicon. Set `SMOLBOX_RUNTIME_VERSION` to `1.16.0`, `1.14.6` or `1.14.1` for an
existing older worker. Consult the
[qualification evidence](../../docs/runtime-1.19.0-qualification.md). For smaller 1.14.6, 1.16.0, 1.16.1 or 1.17.0 disk requests, supply the host's `resize2fs`; see
[host prerequisites](../../docs/compatibility.md#macos-1-14-6-prerequisites).
SmolBox 0.1.5 defaults to 1.16.1; 0.1.3 defaults to 1.16.0. Keep key files private
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
