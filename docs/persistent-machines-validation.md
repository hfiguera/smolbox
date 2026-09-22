# Persistent-machine validation

Validation on 2026-09-21 (America/Denver), using Elixir 1.20.4 and OTP 29.0.6.
The original run used PostgreSQL 17 on native macOS Apple Silicon. The Linux
follow-up below used PostgreSQL 16.15 and the committed implementation.

## Real worker and durable storage

The two-process durable demonstration was run against a smolvm **1.16.1** server
with a prepared Python image, offline networking, one machine slot, and 2 GiB
storage plus 2 GiB overlay requests. PostgreSQL ran in a fresh local test cluster.

The first independent BEAM created and started a machine, wrote a guest file, read
it through another managed command, and exited while retaining the machine. The
second independent BEAM used the same database, partition, fingerprint key, and
encryption key. It read the file, stopped/started the same machine, read the file
again, explicitly deleted it, verified absence, and verified zero resource usage.
The scenario passed twice. The later run observed
`sbxexample-3bg7kxxufy4zb54kbrdq` in both processes. A real-worker regression of the
existing disposable Python/JavaScript staging, execution, collection, and disposal
path also passed (one selected runtime test). Final worker inventory was empty.

This establishes file preservation and durable management recovery for that
worker/platform combination. It does not establish disk recovery after worker
loss, exactly-once upstream execution, cross-worker migration, or production
isolation. The Linux follow-up below independently verifies the persistent-machine acceptance
scenario on that platform.

## Deterministic and PostgreSQL coverage

The root suite exercises simulated HTTP workers and in-memory storage. Added
cases cover sequential commands, retained files and capacity, duplicate identities,
stop/delete conflicts, controller restart, lost dispatch evidence without replay,
failed stops, lost delete acknowledgments, missing machines, ownership mismatch,
unavailable stores, bounded records, and unsafe serialized data.

The memory and PostgreSQL adapters share a machine contract covering concurrent
acceptance, shared disposable/retained reservations, exclusive command admission,
stop/submit races, completion, preserved unknown outcomes, worker takeover,
version checks, assignment history, and verified release. The PostgreSQL suite
uses real SQL transactions and authenticated encryption, including rejection of
machine ciphertext substituted into an execution record with the same identity
and rollback of the active-command slot when SQL rejects the execution insert.

Ordinary root tests do not invoke a real worker. Database tests invoke PostgreSQL
but use synthetic machine observations. The separate two-process demonstration
above supplies real-worker evidence. Qualification remains `:development`. The full CI sequence passed with 256 root
tests (17 runtime tests excluded); the PostgreSQL suite passed 27 tests (28 runtime
tests excluded). Root and durable-example type analysis passed. An actual database
outage probe also confirmed typed store failures for managed-machine reads and
acceptance, with no fallback. See the [structured evidence](evidence/persistent-machines.json).

## Linux follow-up

The same two-process persistent-machine demonstration passed against real smolvm
1.16.1 in the disposable nested KVM lab reached through `ssh linux`, using source
commit `cfda5f1`. The guest ran Linux x86_64, kernel 6.8.0-139-generic, Elixir 1.20.4,
OTP 29.0.6, and PostgreSQL 16.15. The runtime archive matched the previously
verified SHA-256 `e49e5bbae6d65b039ecf1d8b236d20e77427b7bfd131907b27a0819fcdea3fed`;
bundled component checksum checks and the existing worker startup preflight passed.

The offline Python machine used 2 GiB storage and 2 GiB overlay requests. The first
BEAM created `sbxexample-gcp57n3snunsyvoxpiz5`, wrote and read the file, and exited
with its reservation retained. A separate BEAM reconnected through PostgreSQL,
read the file, stopped and restarted the same machine, read it again, then deleted
it. The demonstration verified absence and zero reserved slots, CPU, memory, and
disk. Final worker inventory was empty; teardown left no owned KVM descriptors,
and the outer lab was stopped after exporting evidence.

Both projects compiled with warnings as errors. The ordinary Linux suite passed
256 tests with 17 runtime tests excluded; the PostgreSQL suite passed 27 tests
with 28 runtime tests excluded. These are separate from the real-worker
acceptance demonstration. The offline dependency cache required the locked Mint
1.10.1 source. An initial inventory preflight returned 404 because the harness
used an incorrect URL, before any machine creation; correcting it to
`/api/v1/machines` allowed the complete scenario to run successfully.

This is one successful Linux persistence acceptance run, not a repeat of the full
Linux fault or containment campaign. SmolBox's existing `:development`
qualification remains unchanged: it does not certify hostile multi-tenant host
quotas. That designation is independent of Linux test availability. The structured
evidence records the tested commit, outputs, environment, and exported log hashes.
