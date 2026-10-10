# Durable worker draining tests

This report preserves the environments, results and limits of the original checks.
For configuration and API usage, see [Durable worker draining](worker-draining.md).
An older result does not establish a new test of the current release.

## Recorded checks

Shared memory/PostgreSQL contract tests cover concurrent drain/reservation ordering,
versioned resume, helper admission, duplicate histories and maintenance pagination.
Runtime tests cover two controllers, controller restart, retained commands and
cleanup during draining, static restrictions and unavailable storage. PostgreSQL
tests additionally check rollback and missing-schema behavior. These simulated
worker tests establish the store/controller contract, not worker-side fencing.

A live Linux run with smolvm 1.20.2 and PostgreSQL also exercised the following
sequence across two separate Elixir processes:

1. Create a retained machine, write a file and persist a drain revision.
2. Start a new controller process against the same database. Verify that it reads
   the drain and that a new request expires without a worker assignment.
3. Read the original file, stop and start the same machine, and read it again.
4. Explicitly delete that machine, verify absence and released reservations, then
   inspect the empty maintenance report and explicitly resume with its version.

The worker inventory was empty after this run and the dedicated test service was
stopped. This verifies retained-machine recovery and cleanup during draining; it
does not establish automatic shutdown safety or worker-side request fencing.

The PostgreSQL migration was separately exercised in both directions. Rollback
refused to discard an existing drain revision and left it intact. With only the
test history removed, rollback and reapplication succeeded. The ordinary library,
PostgreSQL adapter and published-dependency community example suites, package
consumer check and static quality checks cover compatibility independently of this
live scenario. No macOS VM campaign was run for this feature.

The [1.22.0 qualification](runtime-1.22.0-qualification.md) records the newer
platform checks. The historical validation above still describes its original run.
