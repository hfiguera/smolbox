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
