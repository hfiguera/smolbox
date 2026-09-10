# Disposable Linux lab

This maintainer lab runs **only on the authorized `ssh linux` machine**. macOS
is used to edit files and open SSH connections; no virtualization, resource,
isolation or recovery tests in this work run on macOS.

The lab prepares a place to investigate stronger guarantees. It does not certify
SmolBox 0.1.0 for hostile code, change its accepted execution profile, or provide
production isolation just by booting a VM. Results describe the exact nested
configuration and pinned inputs recorded with them.

## Layout and budgets

```text
Pop!_OS physical host (ssh linux)
  systemd: independent VM deadline, resource controls and process teardown
  smolbox-lab account: KVM access, no password or interactive login
  128 GiB preallocated ext4 loop volume: images, keys, staging and evidence
    QEMU with KVM, private QMP socket and 1 MiB serial ring
      disposable Ubuntu guest: 4 vCPU, 8 GiB RAM, 100 GiB virtual disk
        Elixir 1.20.4 / OTP 29.0.6 + SmolBox source and locked dependencies
        dedicated smolbox-worker account + SmolVM 1.14.1
          Python / Node microVM, using nested KVM
  operator's lingering systemd user manager
    recovery timer: stopped test VM -> capture status -> verify baseline -> new disk
```

The outer QEMU service has a 400% CPU bandwidth quota, 12 GiB cgroup memory
maximum, zero cgroup swap and 256 host tasks. It requests 8 GiB guest memory;
the additional host allowance covers the outer VMM and its overhead. Temporary
directories are separate 64 MiB memory filesystems charged to the service.
The 100 GiB disk is a guest allocation. A separate 128 GiB host volume bounds
the lab's images, copies, staging, keys and evidence. Its backing file is actually
preallocated, verified through allocated blocks, rather than only sparse-sized.
Filesystem formatting must use `nodiscard` or it can release that reservation.

These are different limits. Host tasks do not count each guest process. CPU
bandwidth is not a per-command CPU-time budget. The outer limit applies to the
whole disposable worker environment, not individually to each SmolVM machine.
Installed host packages, small bootstrap/account/unit files and ordinary OS service
journal metadata live outside the lab data volume. No host-wide logging policy is
changed.

One lock covers every QEMU mode. Only one lab VM can run at a time. The physical
host's existing SmolVM worker and other workloads are separate and must remain
untouched. This machine is not registered as a GitHub runner.

## Host installation

Review `scripts/lab/install-host.sh`, `launch-vm.sh` and
`smolbox-lab@.service`. Copy the scripts to the private operator-owned directory
`/home/humberto/smolbox-lab-bootstrap` on the authorized host, then run:

```sh
ssh -t linux 'sudo bash /home/humberto/smolbox-lab-bootstrap/install-host.sh humberto'
```

The installer needs interactive administrative authentication. It installs
`qemu-system-x86`, `qemu-utils`, `cloud-image-utils`, `socat`, `jq` and `shellcheck`,
creates the account and private volume, and installs root-owned QEMU launcher
code and units. It refuses to adopt unrelated pre-existing accounts or storage.
The storage allocation requires 128 GiB plus at least 64 GiB left free on the
physical host. It adds a persistent mount to `/etc/fstab`.

The operator joins the lab group after reconnecting SSH. Narrow sudoers entries
permit only starting, stopping and resetting the three lab units, plus sending
SIGSTOP to the short-lived `probe` unit. They do not permit arbitrary QEMU
arguments, shells or other systemd units. No VM starts during installation.

Run the operator setup through Linux:

```sh
ssh linux 'bash /home/humberto/smolbox-lab-bootstrap/install-operator.sh'
```

This installs a recovery timer in the operator's systemd user manager and verifies
lingering so it continues after logout. The timer never replays a guest command
or automatically starts a new test. It prepares a clean replacement disk after
a test/probe unit stops. While a test/probe is active, it periodically preserves
bounded cgroup/QMP observations and the last nonempty serial capture. Provisioning
disks are deliberately excluded. The service uses `sg` to activate the granted
lab group even when the existing user manager predates that group membership.

## Pinned guest inputs

`prepare-host.sh` runs on Linux and downloads the Ubuntu 24.04 amd64 cloud image
from the dated `release-20260826` directory, verifying SHA-256
`d0fe84bb5f80853425fa6be28e2c106f30104c3cfe8611933f2e65c9b63f0e30`.
It copies, rather than modifies, the existing approved Linux artifacts:

| Input | SHA-256 |
| --- | --- |
| SmolVM 1.14.1 release archive | `e91786c12808ce87655aa190eb5f6692672cd659a89367b5ec18dace5756af2f` |
| Python artifact | `76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2` |
| Node artifact | `768b8d2158a75abd90ccc73a65a83717aebfe37e62ed91d0db0bb731584df776` |

Upstream source is `e8d09ef616d363004d55b80a6cdb31a4e7e1842d`.
The complete Linux distribution is extracted; a bare `smolvm-bin` is insufficient.
The 20/10 GiB sparse disk templates are decompressed during provisioning before
API request deadlines. Approved artifacts must be readable by the worker.

The recipe bundles the previously validated Linux Elixir/OTP builds from the
existing qualification cache. It records the bundle digest, checks versions
inside the new guest, and fetches and compiles the repository's locked Mix
dependencies there. It never copies personal Hex credentials or SSH agents.
The source is a `git archive` with its full commit recorded; external references,
local caches and credentials are excluded.

The dated cloud image and prepared baseline have exact hashes. Guest OS packages
come from Ubuntu repositories during provisioning and their installed versions
are recorded. This is a repeatable recipe plus an immutable tested baseline,
not a claim that a future apt run reproduces identical bytes. Keep the approved
inputs/baseline to reproduce this deployment; changes require revalidation.

## Provision, seal, run

All commands below run **inside `ssh linux`**, from the private bootstrap directory.
The host installer and volume must exist first.

1. Run `bash prepare-host.sh`. It generates a temporary lab-only SSH key and
   cloud-init seed on Linux and refuses to overwrite existing baseline images.
2. Stage `source.tar` produced by `git archive`, `source-commit.txt`, and their
   SHA-256 entries alongside the verified runtime/artifact/toolchain archives.
3. Run `bash labctl.sh start provision`. This mode permits outbound provisioning
   downloads. SSH listens only on physical-host `127.0.0.1:22460`; use
   `guest-ssh.sh`, which disables agent forwarding and uses its own identity and
   known-hosts file. No management port is opened on the LAN.
4. Copy the staged inputs to `/home/lab/input` in the guest. Wait for
   `cloud-init status --wait`, then run `sudo bash /home/lab/input/provision-guest.sh`
   inside that guest. Reboot to its installed kernel. Verify the provisioned
   marker, `/dev/kvm`, runtime digest and empty health inventory; save those
   observations as `evidence/provisioned.txt` on the physical host.
5. Power off the guest. `bash labctl.sh seal provision` checks and flattens the
   disk, records its SHA-256 and makes the baseline read-only. This is a cold disk
   image, not a live nested-VM memory snapshot.
6. Run `bash labctl.sh reset test`, then `bash labctl.sh start test`. The new disk
   is an overlay of the verified baseline. Test mode uses QEMU restricted user
   networking with IPv6 disabled; provisioning internet access is gone.
7. Transfer the reviewed probes and `verify-guest.sh` to `/home/lab/input`, then
   run `bash /home/lab/input/verify-guest.sh` through `guest-ssh.sh`. Export its
   JSON reports to the host's evidence directory before teardown.
8. `bash labctl.sh capture test` collects actual cgroup counters and QMP data.
   `bash labctl.sh stop test` stops only this unit. The recovery timer then
   verifies the baseline and discards the owned disposable overlay.

An authorized provisioning correction can use `labctl.sh revise provision`
while all units are stopped and no recovery is pending. It starts from the
previous trusted baseline, not a disk exposed to hostile tests. After the
correction, power off and seal again; the prior baseline hash is retained.
Never promote an adversarial test disk into the clean baseline.

The SSH identity is temporary to this private lab installation. Resetting a disk
preserves the baseline's SSH host identity. Rebuilding the lab requires rotating
the client key/seed and deliberately replacing the dedicated known-hosts entry.
Production credentials, host mounts, agent forwarding and unapproved artifacts
are not part of this configuration.

## What the checks establish

`network-probe.exs` checks denied TCP connections from the outer guest to public
HTTPS and selected host endpoints, plus denied UDP DNS through the QEMU proxy.
Successful management commands prove that explicit inbound SSH still works.
These are finite checks of the configured policy, not exhaustive network fuzzing.

`nested-probe.exs` requires Linux/KVM, the pinned toolchain and an empty worker.
It creates a real SmolVM machine through SmolBox, inspects live kernel VM/vCPU
descriptors in the outer guest, stages Python and binary data, preserves a
nonzero exit, collects binary output and verifies stop/delete/absence.
libkrun can close its initial `/dev/kvm` descriptor after creating the VM; the
live VM and vCPU descriptors plus actual execution are the relevant evidence.

`verify-guest.sh` also runs all 14 existing client, managed-runtime and security
characterization cases with the bounded CI runner. Its expected test count
rejects skips, exclusions and partial runs. These include Python, JavaScript,
file handling, streaming, cancellation and uncertain outcomes. They do not
constitute the entire durable-store suite or a new production qualification.

Recovery uses a separate `probe` unit with a 30-second deadline and a 15-second
stop grace period. Capture its PID, cgroup and invocation, send SIGSTOP through
`labctl.sh freeze-probe probe`, then observe systemd terminate it independently
of guest SSH. Verify the original processes and cgroup are gone, the recovery
timer produces a fresh overlay, and a clean replacement boots successfully.
The regular test deadline is 45 minutes; provisioning has a two-hour deadline.

Available serial evidence is bounded by the 1 MiB ring. A frozen or dead QEMU
cannot supply a new ring read; previous successful captures and systemd status
remain useful. Evidence uses fixed filenames under the bounded data volume.
Guest test output uses the existing bounded Elixir runner. Keep private raw logs
and keys out of Git; export only reviewed reports and hashes.

## Retesting shared storage cleanup

The September 10, 2026 comparison of SmolVM 1.14.1 and 1.14.6 is recorded in
[Resource evidence](resource-qualification.md#shared-storage-cleanup-retest).
It uses a new account and one shared 512 MiB tmpfs inside a disposable test VM.
The candidate deployment's separate metadata mount would hide the original
failure mechanism. The regression's UID drop and shared extraction settings
match the earlier exploratory experiment; this is not a new isolation profile.

Start from a clean `test` overlay using the procedure above. Leave the baseline
and original worker unchanged. On the physical Linux host, download the official
`smolvm-1.14.6-linux-x86_64.tar.gz` release archive into the bounded lab staging
directory. Verify SHA-256
`94a1edb0c42b20ac562c3759ed216bab2cab9e27c382f6560969144f7bd1dce3`, then transfer
it through `guest-ssh.sh` to `/home/lab/input/` in the guest. The guest needs no
outbound network. Its existing `/opt/smolbox/runtime` must still contain the
verified 1.14.1 distribution and `/opt/smolbox/catalog` the approved Python image.

Stage the reviewed SmolBox source and locked dependencies in
`/home/lab/cleanup-validation/source`, owned by `lab`, and create the sibling
`reports` directory. The following commands run **inside the disposable guest**
through `guest-ssh.sh`, with the lab's Elixir/OTP environment loaded:

```sh
cd /home/lab/cleanup-validation/source
mix compile --warnings-as-errors
sudo bash scripts/lab/cleanup-regression-control.sh prepare
sudo bash scripts/lab/cleanup-regression-control.sh start 1.14.1
timeout 240 mix run scripts/lab/cleanup-regression.exs 1.14.1 baseline
sudo journalctl -u smolbox-cleanup.service --no-pager -n 250 > ../reports/baseline-worker.log
sudo bash scripts/lab/cleanup-regression-control.sh start 1.14.6
timeout 240 mix run scripts/lab/cleanup-regression.exs 1.14.6 fixed
sudo bash scripts/lab/cleanup-regression-control.sh stop
```

The baseline passes only when it observes the expected failed API deletion and
the same stopped machine. That is **successful reproduction of a failure**,
not successful cleanup. The next `start` explicitly tears down this owned worker
and clears only its test state. It must not be counted as an API deletion.

The fixed case requires successful API deletion, actual storage reclamation,
data directory absence, continued registry absence after restarting the worker
without resetting its storage, and a subsequent execution with file transfer
and verified cleanup. Both cases first verify the shared filesystem, actual
cgroup controls and live nested KVM descriptors. Stop can free one 4 KiB block;
the probe records that small change instead of filling it again from the host.

Reports checkpoint observations outside the full filesystem. A failed assertion
preserves the report and does not replay a command. Stop the exact experiment
service after failures; it also has an independent 300-second deadline. Export
reports, bounded journal output and source hashes to the physical host before
stopping the outer lab VM. The existing recovery timer then restores a clean
overlay. Never seal this exposed test disk as a new baseline.

This client experiment does not upgrade SmolBox's supported runtime version.
Broader compatibility and managed recovery tests are separate work.

## Recovery and removal

Host-side teardown works when the guest worker, database, OS or management SSH
fails. It cannot recover a failed physical-host kernel. The operator confirmed
physical access to restart and recover that host. No physical-host crash or
reboot is part of these tests.

To stop testing, stop only `smolbox-lab@provision`, `@test` and `@probe`, and allow
pending recovery to finish. The baseline can remain for another explicit run.
For complete removal, first disable the operator recovery timer, verify all lab
units/processes are stopped, then have an administrator unmount this specific
volume, remove its exact fstab entry, service/launcher/sudoers files, account and
backing file. Do not run broad VM pruning or remove previous qualification data.
Disabling operator lingering also affects unrelated user services, so restore it
only after considering those services rather than treating it as lab-only state.

## References

- [QEMU invocation and restricted user networking](https://www.qemu.org/docs/master/system/invocation.html)
- [Kernel documentation for nested KVM](https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html)
- [Linux cgroup v2 controls](https://docs.kernel.org/admin-guide/cgroup-v2.html)
- [Dated Ubuntu cloud image](https://cloud-images.ubuntu.com/releases/noble/release-20260826/)

## Recorded validation

[Validation evidence](evidence/nested-kvm-lab.json) was collected on 2026-09-08 UTC
(September 7 in the operator's timezone). Every check ran on `ssh linux` or in its
disposable Linux guest. It records the source and runtime hashes, failed attempts,
actual kernel settings, results and cleanup.

- Real nested KVM execution, binary input/output, nonzero exit and deletion passed.
- All 14 runtime cases passed from the rebuilt baseline in 152.103 seconds.
- Restricted outer-guest TCP/DNS probes passed with private management still usable.
- Frozen-QEMU termination, periodic evidence capture, process/cgroup disappearance,
  automatic disk rebuild, unchanged baseline and clean replacement boot passed.
- All 194 deterministic tests passed separately, plus formatting, compilation,
  dependency-cycle checks, Credo/ExSlop, ExDNA, Credence, Dialyzer, ShellCheck and
  systemd unit validation. The deterministic run's 14 exclusions are the runtime
  cases that were executed separately, not skipped integration evidence.

The nested target exposed a fault-injection fixture's ten-second setup assumption.
Its wait for the execution boundary is now thirty seconds. Command, cancellation,
cleanup and no-replay assertions retain their original limits; library code is
unchanged. The original failure and the subsequent successful run are recorded.

The lab VMs are stopped. A clean replacement disk and the pinned baseline remain,
and the recovery timer remains enabled. The original physical-host SmolVM worker
is healthy at its original PID. The host retains the 128 GiB storage reservation.

These initial checks qualify this lab for the recorded functional/recovery work. No
hard-limit exhaustion campaign, hypervisor escape/fuzzing assessment, new durable
recovery matrix or production certification was performed in that increment. SmolBox 0.1.0's
production-isolation limitation remains accurate.

The separately authorized [Linux candidate campaign](linux-production-qualification.md)
extends this baseline with PostgreSQL and a dedicated bounded worker. It records
later exhaustion, isolation and durable recovery results separately from the
initial lab evidence above. New writable runs must install the candidate's tmpfs
mounts before startup; its preflight refuses missing storage boundaries.
