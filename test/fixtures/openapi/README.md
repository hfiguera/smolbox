# Upstream schema fixture

`smolvm-v1.14.1-subset.json` is a mechanically extracted subset of the OpenAPI
schema exported by the official smolvm v1.14.1 macOS arm64 binary. It contains
eight selected paths and their recursively referenced component schemas.

Source: https://github.com/smol-machines/smolvm/tree/v1.14.1
Commit: `e8d09ef616d363004d55b80a6cdb31a4e7e1842d`.

Full exported schema SHA-256:
`9ccc9eace040b1b44031f1abf9126496d750e8b2ba5bcaa734e7d62bade67bbe`.
Extracted fixture SHA-256:
`050f51b9db3170b12706309cec7a01ab81cfa2870faabb5f3d42d94a70ce416b`.

The upstream schema is covered by Apache-2.0; the upstream license is included
as `LICENSE.smolvm`. The extraction removes unrelated endpoints and schemas;
it does not change their retained definitions. This fixture is not shipped in
the Hex package. It does not establish operational guarantees absent runtime tests.

The pinned exported schema omits `/readyz`, although the tagged source defines
it in `src/api/handlers/health.rs` and both runtime distributions serve it. Its
HTTP-200/empty-body contract is verified directly by the client runtime tests;
no invented definition has been inserted into this exported fixture.

## smolvm 1.14.6

`smolvm-v1.14.6-subset.json` retains the same eight paths and their 19 recursively
referenced schemas from the official Linux x86_64 binary's `serve openapi` output.
It was captured on September 10, 2026, inside the disposable nested Linux lab.
No field definitions were changed. The exported API info version is upstream
metadata, not an assertion of the running server version; health is checked
separately. `/readyz` remains absent from the schema and is exercised live.

Source: https://github.com/smol-machines/smolvm/tree/v1.14.6
Commit: `6c503014629bba91631152728c3081c944653f31`.

Full exported schema SHA-256:
`f3a0cf982a82acc125d1d02d09d707f0467b9867b4e17281d65a461a6b76ef99`.
Extracted fixture SHA-256:
`6c9f935f0a1e72c92eb49e5c382d54ebfb5f41ed3742683360667b0708d8cd26`.

## smolvm 1.16.0

`smolvm-v1.16.0-subset.json` was mechanically extracted from the official Darwin
ARM64 binary on September 13, 2026. The Linux x86_64 export has the same full
schema digest. The eight used paths and nineteen referenced schemas are identical
to the 1.14.6 subset, including the exported API metadata. Runtime health is
verified independently; the metadata is not a runtime version assertion.

Source: https://github.com/smol-machines/smolvm/tree/v1.16.0
Commit: `e1dd54bf7be6d144ad6bdef4ebf310f57809a6a6`.

Full exported schema SHA-256:
`f3a0cf982a82acc125d1d02d09d707f0467b9867b4e17281d65a461a6b76ef99`.
Extracted fixture SHA-256:
`6c9f935f0a1e72c92eb49e5c382d54ebfb5f41ed3742683360667b0708d8cd26`.

## smolvm 1.16.1

The official Darwin ARM64 and Linux x86_64 binaries export identical schemas:
`3486e00380443634f57ec7b1d11fa5da4bcfd9b1c427e8cb287f78178dc977be`.
The new subset retains the same eight paths and nineteen referenced schemas.
Only `MachineInfo` changes, adding optional `image`; the used paths are unchanged.

Source: https://github.com/smol-machines/smolvm/tree/v1.16.1
Commit: `9504e94e3581a1f52c414247edcbcd6d6b49a71a`.
Subset SHA-256: `29e03fa13f67ccdfa86b048fd24713172c80dfeda8431d7b218d893df39a2b94`.
Captured from the official archives during the September 17, 2026 campaign.
As with older captures, exported schema metadata is not a runtime health check.

## smolvm 1.17.0

Captured from the official Darwin ARM64 binary on September 22, 2026 UTC.
The subset retains the same eight paths and nineteen referenced schemas.
Shared schemas are unchanged; file GET now documents directory JSON alongside
binary file responses. Definitions are retained verbatim.

Source: https://github.com/smol-machines/smolvm/tree/v1.17.0
Commit: `d33b5a4adeb844365922cd2a29a89d93a94008ad`.
Full schema SHA-256: `db59464fd2d2b8b95ad344ab6218b81cdf842c29bec5e099262db9d8468a4676`.
Subset SHA-256: `c907bfb2020a58bf0468332c448f56068153aafe98bb56d4a5c39a96e43e0bcd`.
Runtime identity and file media types are checked independently against the worker.

## smolvm 1.19.0

Captured from the official Darwin ARM64 distribution during the September 25,
2026 qualification. The subset retains the same eight paths and their twenty
referenced schemas. Create adds optional credential policy and guest subnet;
start adds an optional external interceptor. Existing required response fields
are unchanged. These additional capabilities are not exposed by SmolBox.

Source: https://github.com/smol-machines/smolvm/tree/v1.19.0
Commit: `572bb694` (release tag, excluding subsequent main commits).
Full schema SHA-256: `e4589b6a1a32973a79cde975785d614b56f8f7b38adae430d19803362adc7fa4`.
Subset SHA-256: `8bc752e993a3152e85ae16e34201adf3c1eaf70eef23a0c6e09604cb10feda88`.
Runtime health and unsupported paused states are checked separately; the schema's
state description still lists only created, running and stopped.
