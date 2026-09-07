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
