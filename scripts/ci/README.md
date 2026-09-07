# SmolBox CI infrastructure contract

The ordinary workflow runs quality, deterministic, durable-store and package
checks on disposable hosted runners. Its path classifier permits live-test skips
only for the narrow documented Markdown/planning scope. Unknown files, empty
diffs, code/configuration changes and every manual dispatch require real-worker
evidence. Renames inspect both old and new paths. Evidence JSON changes are
conservatively treated as requiring validation.

`smolbox-required` rejects missing, failed, cancelled and unexpectedly skipped
dependencies. A code PR can finish its ordinary checks while the aggregate still
fails because trusted live validation is pending. This is intentional. Dispatch
the exact reviewed candidate commit through a maintainer-controlled branch/ref;
live jobs check out the classifier's commit, and their preflight records it.
Validating another branch tip does not qualify the PR's merge candidate.

## Enable protected live workers only after provisioning

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
   Install Python 3.11+ and the platform virtualization dependencies. Setup-beam
   supplies the pinned Elixir/OTP toolchain.
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

`runtime_preflight.py` verifies the actual listener belongs to the selected account
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
Hard resource-abuse certification and benchmark evidence are separate acceptance
items and remain pending; this workflow does not certify those by declaration.
Choose `qualify_runtime: true` when dispatching the reviewed candidate. A dispatch
with the option disabled still fails its required live-evidence gate.

## Bounded reports and local verification

`run_bounded.py` launches one owned process group, bounds elapsed time and captured
output, and requires the exact ExUnit pass count when requested. It rejects zero,
partial, skipped or excluded suites. Normal non-ExUnit commands require exit zero.
Failure reports contain status, byte count and output digest, without raw test
arguments or output. A killed controller is not confirmed guest cleanup: the
external disposable-worker lifecycle remains mandatory.

Only bounded JSON reports are uploaded. VM disks, database payloads, private keys
and guest code/output are excluded. Store/service test files remain private until
the independent teardown. No package publication occurs in these workflows.

Run the Python policy/runner regressions from the package:

```sh
python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
```

For explicitly authorized local development, `runtime_preflight.py --development`
permits a persistent test host and marks that limitation in the report. It is
rejected inside GitHub Actions. It does not turn the local SSH alias into a safe
CI runner. Uncommitted files are recorded in development reports and rejected in
CI. Use reports and real commands as evidence; mocked lifecycle declarations,
unit tests or workflow YAML alone cannot qualify a platform or release.
