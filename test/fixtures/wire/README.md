# Captured wire fixtures

Captured from the official smolvm v1.14.1 macOS arm64 distribution using a
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

The `1.17.0/` fixtures were captured on September 22, 2026 UTC from the official
Linux x86_64 distribution in the disposable nested KVM lab. Source commit:
`d33b5a4adeb844365922cd2a29a89d93a94008ad`; binary SHA-256:
`40b9bc8f24f7cc77c371db4784742e6b6724f09a11b83d63776b944734b7912d`.
The same workloads, response cap and lifecycle normalization apply. Buffered
output and SSE bytes remain verbatim. `directory.json` captures the new JSON
response for a directory; the capture also verifies that `Client.download/4`
rejects it as a binary file. Deletion and empty inventory were verified.

The `1.19.0/` fixtures were captured on September 26, 2026 UTC from the official
Linux x86_64 distribution in the disposable nested KVM lab. Source commit:
`572bb694d7dc6857d5de012c9e24a6e4a857ca27`; binary SHA-256:
`9133f40b13e0d08bb0c7b1c939c0ee4d656681445fd739db9a37ed4b14500582`.
The same bounded synthetic capture and lifecycle normalization apply. Buffered
output and SSE bytes are verbatim; directory JSON remains rejected by binary
download. Deletion and empty inventory were verified. Paused and pausing are
unsupported observations, covered by separate rejection and retention tests.
