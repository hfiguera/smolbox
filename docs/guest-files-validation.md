# Guest path and larger file validation

This unreleased feature passed **development qualification** on smolvm 1.17.0
on Linux x86_64 and macOS Apple Silicon (2026-09-24 UTC). It supports explicit
lexical roots and buffered files up to 16 MiB. See [the guide](guest-files.md) for
the contract and [machine-readable evidence](evidence/guest-files.json) for inputs,
receipt hashes and the final automated-check results.

## Source and reproducibility

The branch started from `4184a6f` with working-tree feature changes. Linux used
input archive SHA-256
`8ad8bfb884816d7d906944c6e7ea7ec2c12090f409b5d34c75a4d4f5f2161fd5`.
All **534 archived files** matched the guest source tree after the campaign;
there were no code overlays. Subsequent changes add documentation, package smoke
coverage and codec combination tests, plus alias formatting in the examples.
They do not change the library behavior exercised by the real-worker campaigns.

The reference smolvm source was `73d4b480`; both workers used qualified official
1.17.0 binaries and the previously approved native Python artifacts. Linux archive
and artifact digests are recorded in the evidence. No upstream code was changed.
The reproducible lab entry point is `scripts/lab/guest-files.sh`; it requires the
existing disposable nested KVM lab and its independently bounded worker setup.

## Real-worker checks

Both platforms ran `test/guest_files_runtime` and the PostgreSQL example
`scripts/guest_files.exs` in separate `prepare` and `resume` BEAM processes with the
same private keys, object root and partition. The worker download cap was explicitly
raised to 16 MiB; default library settings remain unchanged.

| Check | Linux | macOS |
| --- | --- | --- |
| Upload/download exactly 16 MiB with binary, Unicode and space-containing paths | Passed | Passed |
| Client rejects 16 MiB-plus-one upload and oversized response | Passed | Passed |
| Worker rejects a read exceeding its configured 16 MiB cap | Passed | Passed |
| Explicit `/app` cwd and home-directory configuration | Passed | Passed |
| Managed staging readback and 16 MiB artifact collection with matching SHA-256 | Passed | Passed |
| Fresh PostgreSQL controller recovers exact policy and same machine | Passed | Passed |
| Files persist through stop/start and another command | Passed | Passed |
| Explicit deletion, verified absence and reservation release | Passed | Passed |
| PostgreSQL store contract suite, including v9 history/tombstones | 34 passed | 34 passed |
| Final owned machine inventory | Empty | Empty |

The deterministic 16 MiB binary had SHA-256
`5e033aae0f529e46ba459e41e9b6e91dbff95474e13f258188a04aec0c14b62b`.
Both platforms also confirmed that a lexical path policy does not contain guest
symlinks: downloading `/app/link` read a guest-only `/tmp` target, while uploading
replaced the link and left the original target unchanged. Direct access to that
unapproved `/tmp` path was rejected. This is an explicit limitation, not a claim
of filesystem isolation.

Linux retained the worker's five-minute deadline, one CPU quota, 1.5 GiB memory
limit and 96-task bound. The campaign completed in **58.477 seconds**, observed
zero OOM kills and a worker memory peak of 696,500,224 bytes. These are finite
measurements, not throughput or maximum-memory guarantees. The worker stopped
and had no remaining owned KVM descriptors. Phase logs were captured and synced
to the physical host, then exported locally before stopping the outer lab. The
baseline checksum, fresh clean overlay and stopped outer process were verified
after automatic reset; exported receipt hashes still matched. The macOS private
worker and PostgreSQL server were also stopped after verified empty inventory.

## Simulated and build checks

Simulated tests cover directional approval, path traversal and encoding,
unchanged defaults, binary byte preservation, per-file and aggregate limits,
unsupported versions/checkpoints, digest failures, uncertain uploads without
retry, stalled-response deadlines, revoked profile approval before staging,
controller restart/deduplication and retained capacity. Shared memory/PostgreSQL
contracts preserve v9 policy through conflicts, mutations and deleted tombstones.
Codec tests check old envelope rejection, unchanged old fingerprints and v9
composition with background, interactive and workload records.

The coverage run passed **362 tests**, including four doctests and six
properties, with **93.05% library coverage**; 28 opt-in runtime tests were excluded.
The example's forced Dialyzer check passed, as did ExDoc and all local links in
72 documentation pages. Package consumers passed with current and minimum
dependencies. Thirteen focused tests passed on Elixir 1.18.4/OTP 27.3.4.15.
The full `mix ci` run passed, including formatting, unused-lock and compiler
checks, dependency cycles, the full suite, strict Credo, zero-clone ExDNA,
Credence and Dialyzer. An exploratory dev-environment Dialyzer run reported
`EEx.eval_file/2` as unknown; the required test-environment run passed. Real-worker
checks above are separate from simulated HTTP peers and memory-store tests.

## Limits

- All file bodies remain buffered; no streaming, resumable or gigabyte-scale claim.
- Lexical roots do not restrict arbitrary commands or symlink resolution. The
  existing upstream FIFO/open-before-type-check limitation remains.
- Worker read caps and HTTP upload ceilings are different; SmolBox cannot impose
  its policy on other clients accessing the worker directly.
- No checkpoint expansion, recursive transfer, snapshot consistency, automatic
  command replay, file-permission API or production isolation/load qualification.
