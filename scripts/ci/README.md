# SmolBox CI infrastructure contract

`SmolBox CI` (`smolbox-ci.yml`) runs quality, deterministic, durable-store and
package checks on disposable hosted runners for every push and pull request.
It can also be dispatched manually. It contains no real-worker jobs.

Main checks use Elixir 1.20.4 with OTP 29.0.6, matching `.tool-versions`.
Compatibility jobs retain Elixir 1.18.4/OTP 27.3.4.15, Elixir 1.19.5/OTP 28.5
and Elixir 1.20.4/OTP 28.5. Cache keys include the exact main toolchain so OTP 28
builds and PLTs are not reused for OTP 29. The optional live workflow uses the
same main pair; changing its configuration does not supply a successful run.

For local validation, run `mise install`, then `mise exec -- elixir --version`.
A newly installed Elixir distribution may need its own Hex/Rebar installations:
`mise exec -- mix local.hex --force` and `mise exec -- mix local.rebar --force`.
Use `mise exec --` before the commands below to select the repository pin without
changing the user's global toolchain. Compatibility evidence records actual
results separately from workflow configuration.

Run dependency audits sequentially when several projects share one development
host. MixAudit 2.1 uses a shared advisory checkout; concurrent updates can fail
while the command still returns zero. A Git refresh error invalidates that audit
result. Resolve the refresh and rerun it before recording a pass.

`SmolBox Runtime Qualification` (`smolbox-runtime-qualification.yml`) is a separate,
optional manual-only workflow. Provisioning and running its protected worker
infrastructure are outside the first-release scope. It remains available for
future use after an explicit infrastructure decision. It verifies the enablement
variable, records the checked-out candidate commit, and calls the shared `smolbox-live.yml` worker
workflow once for Linux and once for macOS. A dispatch with infrastructure
disabled fails before scheduling real-worker jobs.

`smolbox-ci-tools` runs the standalone ExUnit tooling tests. There is no changed-path
classification or full-history checkout. `smolbox-required` requires every ordinary
dependency to succeed. `smolbox-runtime-required` separately requires candidate
preparation and both platform jobs to succeed. Both gates reject missing, failed,
cancelled and skipped dependencies; neither accepts a skipped required job.
Their commands are `elixir scripts/ci.exs required` and
`elixir scripts/ci.exs runtime-required`, respectively.

A passing ordinary CI run establishes its tested library checks. Release
validation requires successful ordinary CI and the existing bounded real-worker
suites for the same exact candidate commit. Recorded local Linux/macOS runs can
supply this evidence, with source/runtime/image identities, results and verified
cleanup. They establish development-host behavior, not production isolation.
The optional manual workflow does not rerun ordinary CI. If used, dispatch the
reviewed commit through a maintainer-controlled branch/ref; live jobs check out
the recorded commit, and their preflight records it.
Validating another branch tip does not qualify the release candidate.

## Documentation and package checks

Build the site and check its generated local links from the repository root:

```sh
MIX_ENV=dev mix docs --warnings-as-errors
MIX_ENV=dev mix smolbox.ci.docs
```

The docs/package CI job runs both commands. The second command checks local
`href` and `src` files and HTML fragments, including evidence assets that ExDoc's
reference warnings do not cover. It accepts an optional output-directory argument
and fails if no HTML pages exist. It does not request external URLs or establish
that private GitHub links are accessible to a reader.

ExDoc 0.40.4 deliberately references an optional, hosting-provided `docs_config.js`
version-menu script without generating it locally. The checker excludes only
that exact generated script tag; other missing assets fail. Tests exercise a
valid site, missing files/fragments and an absent site. Constructor doctests run
with the ordinary deterministic suite. Developer Mix tasks remain compiled for
maintainer use but are filtered out of public ExDoc navigation.

`elixir scripts/ci.exs package-consumer --report /absolute/path/to/report.json`
builds a fresh archive, checks the explicit package allowlist and starts a separate
production consumer. The getting-started and troubleshooting guides must be in
the archive. Examples, tests, maintainer tooling and external references must not
be in it. For a release, validate both current and minimum consumers against the
same saved archive as described in the implementation plan.

## Dependency cycles

Run `MIX_ENV=test mix xref graph --format cycles --fail-above 0` from the repository
root and from `examples/durable_host`. The root `mix ci` alias and the ordinary
format/compile job check the library and compiled developer/test support files;
the durable-store job checks the example's compiled files separately.

All statically tracked file-dependency cycles fail, including runtime-call cycles.
There are no cycle allowlists. External references and dependencies are outside
these project graphs. This check does not enforce architectural layers or detect
dynamic calls. `mix smolbox.ci.verify_checks` proves the gate with an isolated
two-file cycle and an acyclic counterpart.

## Optional protected workflow: requirements before enabling

The checked-in workflows do not provision workers or configure GitHub protections.
Before setting repository variable `SMOLBOX_TRUSTED_RUNTIME_ENABLED` to `true`:

1. Restrict the runner pool to this repository and trusted workflow dispatches.
   Provide isolated disposable runners labeled `smolbox-disposable` plus
   `Linux`/`X64` or `macOS`/`ARM64`. Do not attach the developer's persistent
   `ssh linux` host or laptop as an untrusted-PR runner.
2. Configure environments `smolbox-linux-runtime` and `smolbox-macos-runtime`
   with required reviewers and allowed candidate refs. Missing environments
   are not a protection mechanism: configure and verify them before enabling
   the repository variable. The job has an additional explicit dispatch guard;
   neither `pull_request` nor `pull_request_target` executes this live workflow.
3. Provision a dedicated worker account/state, the complete pinned 1.14.1
   distribution, native prepared Python/Node artifacts, and a private Postgres
   16.15 database with at least 20 connections. The database must be dedicated
   to this job; tests kill child controllers and create/migrate their own tables.
   Install `curl`, Git, the standard Unix process tools (`ps`, `kill`, `sh`,
   and `lsof` on macOS), and the platform virtualization dependencies. Setup-beam
   supplies the pinned Elixir/OTP toolchain. Host-side Python is not required;
   Python/Node remain installed inside the guest artifacts being tested.
4. Enforce external host quotas and a lifecycle that destroys the whole worker,
   its guests, database and private files on success, failure, timeout, cancellation
   and runner loss. Configure an independent sweeper for abandoned lifecycle IDs.
   Process shutdown and name-prefix cleanup are insufficient. The CI wrapper
   cannot fence delayed exec requests or certify the external reaper.
5. Supply an owned mode-0600 manifest via the runner environment variable
   `SMOLBOX_CI_WORKER_MANIFEST`. Create it when the isolated runner starts its job,
   after scheduling/approval delays. Declare a teardown deadline 55–120 minutes
   ahead; live jobs have a 45-minute timeout and do not auto-cancel previous runs.

The manifest contains deployment references, not secrets. Replace all placeholders
with actual observations; the sample deliberately does not pass preflight:

```json
{
  "schema": 1,
  "platform": "linux",
  "ephemeral_runner": true,
  "expires_at_unix": 0,
  "lifecycle_id": "scheduler-owned-unique-id",
  "worker_pid": 0,
  "worker_url": "http://127.0.0.1:19470",
  "python_artifact": "/private/catalog/python.smolmachine",
  "python_sha256": "replace-with-verified-sha256",
  "javascript_artifact": "/private/catalog/node.smolmachine",
  "javascript_sha256": "replace-with-verified-sha256",
  "database_socket_dir": "/private/postgres/socket",
  "database_port": 25432,
  "database_user": "smolbox",
  "database_name": "smolbox_contract"
}
```

Start the initial server on loopback with
`SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576`. Leave ports 19471 and 19472 free for
owned service-fault fixtures. The wrapper is derived from the selected process's
distribution and checked against the release archive. The fault scenarios launch
their own server on 19471, use the verified `SMOLVM_GUEST_ROLLOUT_HOST_PORT=19472`
override, and refuse to stop an existing listener. Linux fault state uses a new
job-owned directory. On macOS, SmolVM uses account-level state, which is another
reason the account/host must be disposable and dedicated.

`elixir scripts/ci.exs preflight` verifies the actual listener belongs to the selected account
and PID, the executable/wrapper match the downloaded release archives, native
architecture, KVM access on Linux, fixture digests, private database socket, typed
health/readiness and empty inventory. It rejects an overriding `DATABASE_URL`.
The manifest's external isolation and teardown declarations are trusted operator
inputs, not remote attestation. macOS virtualization is established by actual VM
tests, not by checking an OS name. A preflight pass never counts as a live-suite pass.

The live workflow runs all 14 current client/runtime cases, all 25 durable
recovery cases, and restart/prolonged-unavailability/missing-VM service scenarios.
The client/runtime suite includes finite output overflow, blocked observers,
file-transfer caps, packed-image symlink behavior, guest FIFO reads and selected
host/control endpoint probes. Successful characterization of an upstream
limitation is not a claim that the limitation supplies isolation.
Hard resource-abuse certification is incomplete and outside first-release
acceptance; this workflow does not certify it by declaration. The recorded
development-host benchmarks cover their stated workloads and image-cache conditions. The live
workflow does not rerun those benchmarks or establish broader performance claims.
Dispatch `SmolBox Runtime Qualification` for the reviewed candidate when the
infrastructure is ready. There is no runtime toggle in `SmolBox CI`. Successful
ordinary CI supplies no new runtime evidence.

## Bounded reports and local verification

`elixir scripts/ci.exs bounded` launches one owned process group, bounds elapsed time and captured
output, and requires the exact ExUnit pass count when requested. It verifies the
child's independent process group before releasing its startup gate. A TERM-ignoring
descendant is killed even if the leader exits; terminating a BEAM task alone is
not treated as OS-process cleanup. It exclusively reserves the report file before
launching a command. It rejects zero, partial, skipped or excluded suites.
Normal non-ExUnit commands require exit zero.
Failure reports contain status, byte count and output digest, without raw test
arguments or output. A killed controller is not confirmed guest cleanup. The
optional GitHub workflow still requires its external disposable-worker lifecycle;
local runs must verify owned-resource cleanup and report unresolved outcomes.

Only bounded JSON reports are uploaded. VM disks, database payloads, private keys
and guest code/output are excluded. Store/service test files remain private until
the independent teardown. No package publication occurs in these workflows.

The two entry workflows and shared worker workflow live in `.github/workflows/`.
Library jobs run from the repository root, and example jobs run from their
respective `examples/` directories.

The separately authorized [nested Linux lab](../../docs/nested-kvm-lab.md) uses
`scripts/lab/` and the same bounded runtime test runner on `ssh linux`. Its host
deadline and recovery timer were tested against a frozen QEMU process. It is
maintainer infrastructure, not a GitHub runner or a production qualification.

Maintainer code lives under `dev/smolbox/ci/`, outside the Hex package and
production compilation paths. `scripts/ci.exs` loads only those modules using the
installed Elixir/OTP standard library; no Mix dependency fetch is needed for
preflight, aggregation or process control. The modules and their ExUnit tests
are covered by the normal Elixir formatter and quality gates. Tooling code is
excluded from the production-library coverage percentage.

The loopback HTTP helper invokes `curl` with user configuration, proxies,
redirects and retries disabled. Its owned subprocess has both a deadline and a captured-output cap,
including error responses. On macOS, executable inspection matches the kernel
short name to exactly one mapped text file from `lsof`, then checks the release
digest. Spoofed argv names are not trusted; ambiguous mappings fail.

Run the standalone tooling regressions from the repository root:

```sh
elixir scripts/ci_test.exs
```

For explicitly authorized local development, `elixir scripts/ci.exs preflight --development`
permits a persistent test host and marks that limitation in the report. It is
rejected inside GitHub Actions. It does not turn the local SSH alias into a safe
CI runner. Uncommitted files are recorded in development reports and rejected in
CI. Use reports and real commands as evidence; mocked lifecycle declarations,
unit tests or workflow YAML alone cannot qualify a platform or release.

If local macOS forwards the Linux PostgreSQL socket, run the two durable suites
sequentially. The 20-connection prerequisite is per job; sharing that database
between simultaneous suites can exhaust it. Protected CI jobs require separate
dedicated database instances.
