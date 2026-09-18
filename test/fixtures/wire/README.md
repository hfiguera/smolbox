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

The `1.16.0/` fixtures were captured on September 13, 2026 using the official
Linux x86_64 release inside the disposable nested KVM lab. Source commit:
`e1dd54bf7be6d144ad6bdef4ebf310f57809a6a6`; binary SHA-256:
`487f20b84053ce6441c67d4d8af35fc028d3bfc7fcfd2da4309c070930fe46a1`.
The same capture script, synthetic workloads, response cap and normalization
rules apply. Buffered bytes and SSE framing remain verbatim. Capture completed
with verified deletion and an empty inventory. These responses do not establish
completion of the broader 1.16.0 qualification campaign.

The `1.16.1/` fixtures were captured on September 18, 2026 (UTC) using the official
Linux x86_64 release in the disposable nested KVM lab. Source commit:
`9504e94e3581a1f52c414247edcbcd6d6b49a71a`; binary SHA-256:
`017f61853a8f19450472052080f95cd8ef5b80b61d1715e4524c67ea085f11a5`.
The same capture script, workloads, response cap and normalization rules apply.
Buffered output and SSE framing remain verbatim. Capture finished with deletion
verified and an empty inventory. The separate qualification report records the
broader compatibility and network enforcement results.
