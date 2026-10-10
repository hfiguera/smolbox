# Measurements and worker capacity tests

This report preserves the environments, results and limits of the original checks.
For configuration and API usage, see [Measurements and worker capacity](worker-measurements.md).
An older result does not establish a new test of the current release.

## Recorded checks

Decoder and simulated HTTP/runtime tests cover optional and malformed measurements,
response bounds, identity mismatches, retained accounting, unavailable stores,
unavailable workers, unsupported profiles and draining reports. They do not prove
host metric accuracy or hard resource enforcement.

The opt-in real-worker suite exercises machine measurements while running and
stopped, CPU counters across commands, offline network telemetry, capacity and raw
metrics, followed by verified machine cleanup:

```sh
mix test test/runtime --include runtime --warnings-as-errors
```

Use the worker and artifact setup in [CI validation](https://github.com/hfiguera/smolbox/blob/main/scripts/ci/README.md).
On 2026-09-29, the 14-test real-worker suite passed on physical Linux x86_64
(`systemd-detect-virt`: `none`) with smolvm 1.20.2, Elixir 1.20.4 and OTP 29.0.6.
It also checked the managed worker report after cleanup and an admission explanation
while draining. The machine inventory was verified empty, then the dedicated test
worker was stopped and confirmed inactive.

PSS was unavailable in a live inspection; the API preserved `nil`. The offline
fixture also omitted egress. Decoder tests cover numeric values for those optional
fields, but this run does not establish live branch PSS or virtio-net traffic
accuracy. These new APIs have not been rerun on macOS. No benchmark, hard quota or
automatic admission policy is claimed.

The [1.22.0 qualification](runtime-1.22.0-qualification.md) records the newer
platform checks. The historical validation above still describes its original run.
