# Captured wire fixtures

Captured from the official SmolVM v1.14.1 macOS arm64 distribution using a
prepared Python artifact with guest networking disabled, on 2026-09-06.
Machine names, creation timestamps, and process IDs are normalized in lifecycle
responses. Exec response bytes and SSE framing are retained exactly.

Upstream: https://github.com/smol-machines/smolvm/tree/v1.14.1
Source commit: `e8d09ef616d363004d55b80a6cdb31a4e7e1842d`.
The synthetic workload emits bytes `00 ff fe`, stderr `err`, and exit code 7;
the SSE workload prints `café` followed by a newline and exits with code 0.

`health.json` was captured from the same pinned macOS distribution on
2026-09-07 at 03:02 UTC with an empty inventory. `/readyz` returned HTTP 200,
zero content length and no Content-Type; that empty response has a distinct
transport contract and does not relax JSON or SSE media-type validation.

The `1.14.6/` fixtures were captured on September 10, 2026 from the official
Linux x86_64 v1.14.6 distribution in the disposable nested KVM lab. Source commit:
`6c503014629bba91631152728c3081c944653f31`; binary SHA-256:
`cc1f9b5f14613191ca83c706d52f4350f69b69a6c431c867cd662b51cb36d7d6`.
`scripts/lab/capture-wire.exs` uses the same synthetic output workloads and a
65,536-byte response cap. Only lifecycle names, creation times and PIDs are
normalized. Responses include the new `blockIo` and resource observation fields;
these do not become resource enforcement claims. Execution bytes and SSE framing
remain verbatim. The owned VM was stopped and deleted, and inventory was empty.
