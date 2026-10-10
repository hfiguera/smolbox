# Testing reports

This page collects test results and measurements for readers who need to inspect
how a feature was checked. Start with [Getting started](getting-started.md) to run
the example, or [Supported platforms](supported-platforms.md) to select a worker.

Reports retain the source revision, worker version, environment, failures and
limits of the original run. An older result is not a new test of the current
release, and passing one workload does not establish production isolation.
Supported use remains `:development`.

## How to read the results

Unit and property tests check parsing, identities and state transitions. Contract
tests exercise storage and simulated worker faults. Real worker tests additionally
check VM creation, command execution, file transfer and deletion on the named host.
Each report identifies which kind of check was performed.

JSON records supply the exact inputs and outcomes behind a report. They are
optional supporting material; you do not need to understand them to run a guide.
Performance measurements describe their particular workload and host.

## Worker versions

| Report | What it covers |
| --- | --- |
| [smolvm 1.22.0](runtime-1.22.0-qualification.md) | Linux and macOS checks for the current default worker, including failures and upgrade limits |
| [smolvm 1.20.2](runtime-1.20.2-qualification.md) | Earlier worker checks and retained-state restrictions |
| [smolvm 1.19.0](runtime-1.19.0-qualification.md) | Earlier execution, recovery, saved-state and network checks |
| [smolvm 1.17.0](runtime-1.17.0-qualification.md) | Earlier execution, recovery and persistent workspace checks |
| [Compatibility test history](compatibility.md) | Older runtime, toolchain, package and feature campaigns, including 1.14.x and 1.16.x |

## Feature checks

| Report | What it covers |
| --- | --- |
| [Getting Started Livebook](evidence/getting-started-livebook-0.4.2.json) | The Linux 0.4.2 package candidate's execution, output collection and cleanup; its configuration and limits are recorded in the JSON |
| [Persistent machines](persistent-machines-validation.md) | Retained files, stop/start, controller recovery and deletion |
| [Port mappings](port-mappings-validation.md) | Guest HTTP service access, ownership and conflicts |
| [Long commands and background launch](long-running-exec-validation.md) | Command budgets, background launch and recovery |
| [Interactive terminals](interactive-terminals-validation.md) | Input/output, exit observation, disconnects and recovery |
| [Startup workloads](workloads-validation.md) | Console diagnostics and unsupported restart behavior |
| [Guest files](guest-files-validation.md) | Approved paths, larger transfers and file limits |
| [Images and registry artifacts](images-and-registry-artifacts-validation.md) | Provisioning, image operations and credential boundaries |

The [exports](machine-exports.md#validation-and-limits),
[managed checkpoints](managed-checkpoints.md#persistence-and-upgrades) and
[branches](managed-branches.md#durable-adapters-and-compatibility) guides retain their focused
saved-state results. Worker operations and storage checks are summarized in
[Compatibility test history](compatibility.md#worker-operations-and-storage-in-0-4-0).

## Deployment and performance

- [Resource and deployment tests](resource-qualification.md) record the original
  lab and subsequent constrained Linux deployment, including storage exhaustion
  and worker failure. The tested controls depend on that deployment.
- [Provisioning measurements](provisioning-performance.md) compare fresh machines,
  disk exports, checkpoints, branches and reuse on one physical Linux workload.

## Run the checks

From a checkout, `mix ci` runs deterministic checks without a worker. Use
`MIX_ENV=dev mix docs --warnings-as-errors` and `MIX_ENV=dev mix smolbox.ci.docs`
to build the site and verify local links and fragments. Real worker checks require
a prepared, isolated host; follow the repository's
[CI guide](https://github.com/hfiguera/smolbox/blob/main/scripts/ci/README.md).
