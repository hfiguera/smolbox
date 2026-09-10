# Upstream schema fixture

`smolvm-v1.14.1-subset.json` is a mechanically extracted subset of the OpenAPI
schema exported by the official SmolVM v1.14.1 macOS arm64 binary. It contains
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

## SmolVM 1.14.6

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
