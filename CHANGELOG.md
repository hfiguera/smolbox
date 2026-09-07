# Changelog

## 0.1.0-dev

Implementation and upstream compatibility qualification in progress; unreleased.

Managed runtimes now emit bounded, redacted asynchronous telemetry with separate
stage timings and notification counters. Slow handlers and a dispatcher restart
are isolated from the coordinator/execution subtree. Notifications remain lossy;
stored execution evidence is authoritative. Worker inspection exposes configured
capacity and allocation floors alongside health and compatibility observations.

Worker configuration now requires an explicit `allocation_floor` for runtime and
artifact disk templates plus VMM overhead. Profiles below this floor are rejected
before acceptance and before recovered prepared work dispatches. SmolVM 1.14.1
can retain a 20/10 GiB template while reporting a smaller request. The examples
use profile revision v2 with 20/10 GiB disks and 768 MiB host overhead. Existing
saved specs remain unchanged; inspect/reconcile their original identities instead
of resubmitting a changed spec under the same key. This is an unreleased API
change and does not certify hard host resource quotas.
