# Persistent-machine validation

Development-branch validation on 2026-09-21 (America/Denver), using Elixir 1.20.4,
OTP 29.0.6, PostgreSQL 17, and native macOS Apple Silicon.

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
isolation. Linux persistent-machine live qualification has not been run in this
change; existing Linux disposable execution evidence is not new feature evidence.

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
