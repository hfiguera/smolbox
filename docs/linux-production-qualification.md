# Linux production qualification work

Status: the bounded Linux campaign and frozen-VM recovery check passed.
The published 0.1.0 development qualification is unchanged.
The maintainer authorized this follow-up after the disposable nested lab passed
its functional and recovery checks. All execution and exhaustion testing for this
work takes place on `ssh linux`, inside its disposable outer VM.

## Candidate scope

Linux x86_64, pinned SmolVM 1.14.1 and the existing approved Python/Node artifacts,
one untrusted execution at a time, no external networking, no production secrets,
no host mounts, no arbitrary images, no background jobs, and no machine reuse
between executions. Trusted operators control artifacts, deployment and admission.
Guest code is allowed to be hostile, including guest root; guest cooperation is
not an enforcement boundary. This work does not qualify macOS.

The outer QEMU configuration and its immutable baseline remain a separate
containment and recovery boundary. A nested result applies to that configuration;
it is not evidence for an arbitrary bare-metal SmolVM installation.

```text
Physical Linux host
└── QEMU unit: 12 GiB charged memory, 400% CPU, 256 host tasks
    └── Disposable Linux guest: 4 vCPUs, 8 GiB memory, 100 GiB virtual disk
        ├── Trusted Elixir controller, PostgreSQL and evidence
        └── Worker unit: 1.5 GiB charged memory, 100% CPU, 96 host tasks
            ├── SmolVM API on a private Unix socket
            └── VMM and its 256 MiB microVM running guest code
```

The physical host reserves and bounds all lab storage separately at 128 GiB.
The worker's writable filesystems have their own smaller limits below. Exhaustion
of one layer is not evidence that every other layer has been exhausted or tested.

## Acceptance requirements

- [x] Verify exact runtime, artifacts, actual cgroup settings and storage mounts
  before admitting code; refuse missing or weaker enforcement.
- [x] Bound the worker and its VMM descendants independently of client timeouts.
  Distinguish CPU bandwidth from CPU time, charged memory from RSS, and host tasks
  from guest processes. Do not rename existing unsupported options as supported.
- [x] Separate writable VM/cache storage from worker control metadata; reproduce
  disk exhaustion and verify cleanup and a subsequent execution.
- [x] Exercise guest memory, CPU, process and output abuse; separately drive the
  worker's host cgroup to its limits and record kernel denial/OOM counters.
- [x] Exercise stalled consumers, cancellation, deadlines, worker failure and
  database unavailability without command replay or premature capacity release.
- [x] Test file traversal, symlinks, special files, credentials and control
  endpoints. State boundaries that remain unsupported explicitly.
- [x] Verify failure recovery, complete process removal and clean next execution.
- [x] Repeat deterministic, real-runtime, durable-store and quality checks on the
  final source. Preserve failed attempts and hashes alongside passing evidence.
- [x] Document the supported deployment contract and remaining blockers based on
  observed results. Do not infer production safety from a passing test count.

## Enforcement references

Linux cgroup limits cover descendant host processes; guest process counts are a
separate kernel domain. See the [kernel cgroup v2 documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html).
Installed systemd manuals and pinned SmolVM source are checked alongside actual
behavior. Review source at `e8d09ef616d363004d55b80a6cdb31a4e7e1842d` without
modifying the external reference checkout.

## Candidate deployment

`scripts/lab/install-candidate.sh` installs the candidate only inside the
disposable `smolbox-nested` guest. It does not change the physical host's worker.
`smolbox-qualification.service` owns the API server and all VMM descendants under
the dedicated `smolbox-qual` account. `candidate-policy.sh` checks the effective
supervisor deadline, stop and restart policy. `worker-preflight.sh` checks actual
cgroup and storage settings, network namespace, transfer settings and pinned
executable/image bytes before the server starts. The API uses
`/srv/sbq/run/api.sock`, accessible only to the worker and its
trusted operator group. The worker has a private network namespace with loopback
only. Its filesystem view is read-only except for explicit bounded state paths.

| Boundary | Candidate setting | Meaning |
|---|---|---|
| Worker CPU | `cpu.max = 100000 100000` | One CPU of bandwidth per period, shared by server and VMM processes |
| Worker memory | `memory.max = 1610612736`, swap zero | 1.5 GiB cgroup charged memory; not a per-process RSS setting |
| Host tasks | `pids.max = 96` | Host processes/threads in that cgroup; not guest PID count |
| VM/cache storage | Separate 768 MiB tmpfs | Includes disks, extracted layers and VM logs; sparse logical disk size remains 20/10 GiB |
| Control metadata | Separate 64 MiB tmpfs | Guest disk writes cannot consume this filesystem's free blocks |
| API socket directory | Separate 4 MiB tmpfs | Includes all writable API socket-directory entries |
| Temporary files | Two 32 MiB private tmpfs mounts | Also charged to the memory boundary when written |
| Worker lifetime | 300 seconds, five-second stop grace | Independent of the Elixir controller, worker API and guest response |
| Guest allocation | 256 MiB; one or two vCPUs in the tests | Does not substitute for the worker limits above |
| File transfer | 1 MiB worker cap | Client and declared-file caps remain independently required |

The whole outer VM is still bounded by the physical-host lab configuration.
Worker logs sent to the guest journal have a rate limit and the existing bounded
journal configuration. Controller state, PostgreSQL and evidence remain outside
the untrusted worker's writable filesystems, inside the outer VM. Test-only
fault injectors deliberately join the worker cgroup to exercise its actual
host-process limits; guest child counts are measured separately.

`candidate-control.sh` stops and verifies removal of the exact owned deployment
before resetting its three private filesystems. It does not erase the durable
controller store. Unknown executions retain their original identity and outcome
uncertainty; a stopped worker does not imply the command never ran. The candidate
requires one trusted admission authority and one execution at a time. Direct API
access by untrusted callers, arbitrary image uploads and concurrent controllers
are outside this scope.

The runtime fixtures use a 60-second request budget with a 55-second receive
budget, matching the managed profile's one-minute preparation allowance. Cold
nested startup can exceed the ordinary fixture's shorter receive budget. The
durable example retains its default worker request budgets. Neither setting
extends a command's declared timeout or a scenario's explicit observation or
cancellation deadline. Expired requests remain uncertain; they are not retried
automatically.

After a stop request, the control script polls for complete process absence for
a bounded interval before admitting a new execution or erasing state. Systemd
can return before the last orphan has been reaped. A pending process is never
treated as absent solely because `MainPID` is zero. A process that remains after
the observation window prevents restart and requires outer-VM recovery.

## Results and corrections

The first completed disk probe filled all 805,306,368 bytes of the VM/cache mount.
Guest writes failed with `EIO` after 591,396,864 acknowledged bytes. The metadata
mount still had free space; ownership-checked stop, delete and absence inspection
all succeeded. This fixes the reproduced shared-filesystem cleanup failure for
this deployment; it does not change upstream's behavior on shared storage.

A host-process memory injector reached exactly 1,610,612,736 charged bytes. The
kernel recorded an OOM kill and systemd stopped the worker. Separate CPU and task
injectors recorded throttling and fork denial. A test setting of `MemoryMax=2G`
was rejected by preflight. These observations do not qualify a guest process-count
limit or CPU-time budget; those library options remain unsupported.

The first memory workload fixture incorrectly expected an `oom_kill` key in this
artifact's `/proc/vmstat`; the key was absent. The corrected finite allocation
uses the child exit signal and guest kernel OOM log. Failed fixtures and test
wiring attempts are retained separately from passing results.

The final worker configuration passes:

| Check | Recorded result |
|---|---|
| Deterministic suite | 194 passed; the 14 runtime cases execute separately |
| Real runtime suite | 14 passed in 171.023 seconds |
| PostgreSQL store | 16 passed in 3.057 seconds |
| Durable recovery matrix | 25 passed in 571.361 seconds |
| Additional durable faults | Worker OOM, database outage and the actual 300-second worker deadline passed; one dispatch per execution, unknown result preserved, absence verified before releasing capacity |
| Guest workload probes | All ten passed, including Python, Node, memory, CPU, processes, disk, output, stalled reader, named isolation routes and file handling; each verified owned-VM absence |
| Host resource exhaustion | CPU throttling, task denial and OOM kill observed in actual kernel counters; all owned processes removed |
| Negative startup cases | All eleven rejected before the API server started; restored worker healthy |
| Sampled process containment | 600 samples and 1,005 live-process observations found no process outside the worker cgroup; this is sampled evidence, not atomic lifetime attestation |
| Quality | Formatting, compilation, dependency checks, cycle checks, Credo, ExSlop, ExDNA, Credence and Dialyzer passed; coverage 95.40% |
| Analyzer canaries | Bad and clean compiler, xref, Credo, ExSlop, Credence, ExDNA, Dialyzer and coverage fixtures executed and produced the expected outcomes |

The negative cases weaken memory, CPU, task or swap limits; disable Landlock or
the private network; remove the deadline; alter stop/restart policy; corrupt an
approved artifact; or remove a storage mount. Supervisor and worker preflights
both form part of admission. Filesystem capacity values are checked before
execution and actual denials are tested separately.

Failed attempts remain part of the record. Initial runtime fixtures did not
forward Unix sockets through every helper. Cold startup also exceeded short
observation budgets, and one immediate post-stop process check raced final
teardown. Recovery fixtures needed a longer setup synchronization wait under the
CPU quota. A shortened worker deadline could expire before dispatch; the final
test uses the full 300 seconds and explicit readiness output. An attempted
runtime update of `RuntimeMaxSec` was unsupported by systemd 255, so policy is
set before startup. Formatting, ShellCheck and a complexity gate also caught
implementation mistakes; corrected commands were run again. These failures are
not counted as successful tests or silently omitted.

[Reviewed evidence](evidence/linux-production-qualification.json) records source
hashes, pinned inputs, measurements, successful reports and retained failures.
The code is a working tree based on `d848b04cbeb813aa547f382ddf67599e0d23d80c`,
not an already tagged release candidate. No tests ran on macOS.

The physical host independently terminated a frozen QEMU process, verified its
process/cgroup and management port were gone, rebuilt the disposable disk, and
booted a replacement without the previous guest marker. The retained baseline's
SHA-256 is `4ff59594af008ff0efb517e9c70cb90d5cf7c240dc0f71d53a162c7b4a0eea2d`.
All 38 qualification/test source hashes matched after replacement. A further
real KVM execution and owned-VM deletion passed in 8.797 seconds, and the worker
was stopped. Final package verification and stopped-lab status are recorded in
the source-only [handoff report](linux-production-handoff.json).

## Reproduce the candidate

This is a maintainer deployment experiment, not a Hex package feature or an
installer for an arbitrary host. Start with the verified baseline and host
controls in [the nested lab guide](nested-kvm-lab.md). Provisioning must also
install PostgreSQL 16, create the `lab` role and `smolbox_contract` database, and
resolve the locked durable-example dependencies before restricted testing.
For the recorded Ubuntu baseline, those provisioning steps were:

```sh
sudo apt-get install -y postgresql-16=16.15-0ubuntu0.24.04.1
sudo -u postgres createuser lab
sudo -u postgres createdb -O lab smolbox_contract
source /etc/profile.d/smolbox-lab.sh
cd /opt/smolbox/source/examples/durable_host
mix deps.get
```

Create the role/database only on the fresh baseline, or verify existing ownership
before using them. These are disposable test credentials and data. The recorded
systemd version is `255.4-1ubuntu8.17`; the outer guest kernel is
`6.8.0-139-generic`. If pinned packages or images are unavailable, stop and review
new inputs rather than silently upgrading the qualified target.
The qualification account and its filesystems are recreated inside each fresh
outer guest. The installer deliberately refuses another hostname, hypervisor or
operating system. Preflight also pins the guest kernel and architecture.

This baseline disables the original guest TCP worker. Use `candidate-checks.sh`
for it; the original `verify-guest.sh` reproduces the first lab's TCP setup.
`verify-recovery.sh` detects the candidate and verifies its Unix endpoint after
rebuilding the outer VM.

Inside the restricted guest, as `lab`, install the candidate with:

```sh
cd /opt/smolbox/source
sudo bash scripts/lab/install-candidate.sh
```

Reconnect the guest SSH session after first installation so `lab` receives its
new group membership. Run the following sequentially, with no other controller
using the candidate socket:

```sh
source /etc/profile.d/smolbox-lab.sh
cd /opt/smolbox/source
for scenario in smoke node memory cpu processes disk output slow_reader isolation files; do
  sudo bash scripts/lab/candidate-control.sh start
  mix run scripts/lab/qualification-probe.exs "$scenario"
  sudo bash scripts/lab/candidate-control.sh stop
done
bash scripts/lab/host-boundaries.sh
sudo bash scripts/lab/verify-candidate-admission.sh
bash scripts/lab/candidate-checks.sh
```

Each `start` erases only the stopped candidate's verified private filesystems.
It must never run concurrently with active work. The test-only
`SMOLBOX_LINUX_CANDIDATE=true` switch resets that deployment before each runtime
case and selects its Unix socket; it does not change library behavior. Ordinary
worker tests retain their existing endpoints and lifecycle.

`durable-candidate.exs` adds worker OOM, PostgreSQL outage and independent worker
deadline cases. Run it from `examples/durable_host`, with the same environment
as `candidate-checks.sh`, through `mix run`. Its scenario argument is
`worker_oom`, `database_outage`, or `worker_deadline`. Each case submits once,
checks the persistent dispatch ledger, restarts the controller with its original
keys and store, and verifies that resubmission returns the original unknown
execution without replay. Capacity is released only after owned absence is
verified. The deadline case uses the actual 300-second unit setting. Its guest
command sleeps for 300 seconds after boot, so the independent worker clock
expires before the command's own timeout. An earlier shortened 15-second probe
was too short to reliably admit a command during cold startup; its failed setup
is retained rather than counted as execution-deadline evidence.

The full quality command is `mix ci`. Run the analyzer canaries and production
package consumer through `scripts/ci.exs` as described in the CI guide. All of
these commands run on Linux. The private bounded runner
`elixir scripts/lab/run-check.exs LABEL EXPECTED COMMAND...` retains a diagnostic
log and summary, imposes a 20-minute command deadline and 256 KiB output bound,
and verifies an exact ExUnit count when `EXPECTED` is nonzero. Use a new label
for a retry; do not discard a failed report.

Reports live in `/home/lab/qualification`. Export reviewed top-level reports to
the physical host before stopping the outer VM or its 45-minute deadline. Its
recovery timer discards the writable guest disk. Nested `durable-*` directories
contain private test keys and must not be published. Stop the candidate and the
outer test unit, verify process removal and recovery, and preserve the existing
physical-host worker.

## Limits of the evidence

- These are finite abuse and failure experiments on one pinned nested Linux
  deployment. They do not prove absence of kernel, hypervisor, VMM or agent
  vulnerabilities. No escape fuzzing or independent security review was performed.
- The deployment supplies the resource controls. SmolBox 0.1.0 still accepts only
  `qualification: :development` and rejects the unsupported hard-control fields.
  The scripts do not create a portable production profile in the library.
- CPU bandwidth is bounded, not accumulated CPU time. Charged cgroup memory is
  bounded, not per-process RSS. The host task count does not bound guest PIDs.
  The VM/cache quota is shared by one worker and one execution, not a per-file
  or multi-tenant reservation guarantee.
- A guest symlink can point outside `/workspace` within the guest filesystem.
  Lexical path validation is not canonical workspace containment. Special-file
  reads can require a client observation deadline and whole-VM cleanup.
- Seccomp, no-new-privileges and empty effective capabilities are observed on
  every VMM thread. Landlock is requested in enforce mode and its active LSM and
  exact kernel are checked. Pinned upstream ignores the successful call's
  `RulesetStatus`; an enforce flag alone is not a portable fail-closed guarantee.
  This campaign does not directly prove every Landlock or seccomp denial rule.
- Tests probe named credential paths and TCP/vsock endpoints. They do not cover
  every possible device, protocol, syscall or malicious archive. Approved images
  and runtime inputs, the controller and operator remain trusted.
- The worker deadline relies on the outer guest's kernel. If that kernel stops
  responding, the physical-host QEMU deadline is 45 minutes plus its stop grace,
  not the worker's 300 seconds. Physical-host failure requires operator recovery.
- Concurrent controllers, active-active fencing, external networking, arbitrary
  images, persistent guests, secrets inside guests, macOS host limits and a public
  multi-tenant service are outside this candidate. A change to these assumptions,
  kernel, runtime, images or deployment requires new evidence.

Any production decision must name this exact deployment and these limits. The
general published 0.1.0 disclaimer remains accurate; it must not be replaced by
an unrestricted claim that SmolBox safely runs arbitrary untrusted code.
