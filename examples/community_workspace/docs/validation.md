# Workspace validation — 2026-09-23

The app was tested using **Hex SmolBox 0.2.0** (the committed lockfile), Phoenix
LiveView, PostgreSQL 17, headless Chromium, and the official native **smolvm
1.17.0 on macOS Apple Silicon**. The worker used isolated private directories,
a Unix API socket, a 16 MiB transfer cap, working host `resize2fs`, and an approved
Python `.smolmachine` image. No library path dependency or patched worker was used.

This is development qualification of this local example. The browser walkthrough
was not repeated on Linux; the existing package's Linux qualification is separate
evidence. `ssh linux` remains available for a subsequent platform campaign.

## Real browser and worker results

| Check | Result and retained evidence |
|---|---|
| Create/start | Created from the browser; startup workload served the initial project. |
| Successive commands | A write and later read used the same retained machine. |
| Larger transfers | Uploaded and downloaded 2,097,152 bytes; matching SHA-256 `5256ec18f11624025905d057d6befb03d77b243511ac5f77ed5e0221ce6d84b5`. |
| Background launch | Typed PID evidence; resubmitting the same browser request did not increment the launch marker. |
| PTY | Real input/output; `stty size` changed from 13×158 to 13×114; Escape moved focus out; `exit` produced observed code 0. |
| Controller restart | Same durable UUID, files and background marker count after a new app process. |
| Stop/start | Same file hash and marker; startup count increased once and edited HTTP page became reachable again. |
| Narrow browser | 390px layout without horizontal overflow; real terminal input/output, dimensions and exit. |
| Database outage | Stopped the real PostgreSQL server; retained view showed unavailability and disabled mutations. Restart recovered the same machine. |
| Explicit deletion | Cancelled confirmation kept the machine; confirmed deletion verified absence and released all reservations. Independent worker inventory returned `{"machines":[]}`. |

Raw bounded evidence lives in [evidence/](evidence/):
[before restart](evidence/before-restart.json),
[after restart](evidence/after-restart.json),
[narrow terminal](evidence/narrow-terminal.json),
[store outage](evidence/store-outage.json),
[deletion](evidence/deletion.json),
[durable final record](evidence/deleted-store.txt), and
[independent inventory](evidence/worker-inventory.json).
The final record has `reservation: nil`, a verified absence timestamp, and zero
slots, CPUs, memory and disk charged. Evidence was exported before cleanup.
Temporary app, worker and PostgreSQL processes were stopped after validation;
configuration/history were retained privately.

The reproducible two-phase script is `scripts/browser-walkthrough.mjs`. It
asserts behavior rather than merely taking screenshots. The optional 305-second
foreground example was not timed against the real worker in this campaign;
application tests check the approved timeout and wire intent, and the package's
long-running execution qualification covers that upstream capability.

## Problems found and resolved

- The initial terminal configuration exceeded the profile's output buffer budget.
  It now uses the approved 64 KiB cap.
- An early browser test typed before terminal attachment became ready and then
  closed its tab on timeout. The durable terminal became **unknown**, the machine
  remained retained, and subsequent work was blocked. We stopped the controller,
  verified/stopped the owned incarnation, terminated and restarted the dedicated
  worker listener to drain old requests, and explicitly resolved the stopped
  incarnation. The unknown execution history remained. The corrected walkthrough
  waited for the real shell prompt and passed; it did not automatically replay the
  interrupted terminal.
- File-selection events initially rotated a request token more than once for the
  same values. The browser hook now rotates identities only when form values
  change; unchanged resubmission retained the observed background launch count.
- The visual pass fixed terminal styles leaking into xterm internals and a narrow
  primary-button wrap. The independent Impeccable reviewer requested neutral
  “Mapped service” wording and accessible asynchronous outcome announcements.
  Both fixes were scored resolved. Distinct request IDs ensure successive equal
  results still change the live-region text. The named reviewer agent type was
  unavailable, so a fresh independent agent used the skill's fallback contract.

## Simulated and repository checks

These are separate from real-worker evidence:

- **18 application tests passed** with PostgreSQL and a simulated worker/terminal
  peer: durable restart, concurrent duplicate identity, changed-payload rejection,
  unknown blocking/cancellation/file conflicts, file limits, stopped reservations,
  launch PID types, worker/store failures, browser disappearance, web host policy,
  terminal input/resize/output/exit/owner death/backpressure, accessible outcomes,
  deletion and retained identity.
- **362 repository checks passed** through ExUnit (4 doctests, 6 properties,
  352 tests); 28 live/runtime tests were excluded from the ordinary suite.
- **34 durable-host tests passed**, with 29 runtime tests excluded. The unchanged
  shared adapter also passed Dialyzer and dependency-cycle checks.
- Minimal host compilation and dependency-cycle checks passed.
- Root/app formatting, warnings-as-errors compilation, root strict Credo,
  duplication detection, root Dialyzer, dependency-cycle checks, 23 CI-tool tests,
  documentation generation and 73 local documentation link checks passed.
- Frontend assets built successfully. No JavaScript errors were reported by the
  final real-worker walkthrough. Desktop 1440px and mobile 390px captures had no
  horizontal overflow; the one manual Impeccable detector run reported no findings.

Ordinary CI now requires the community workspace job: Hex dependencies, PostgreSQL,
format/compile, npm asset build, and the application tests. It does not need a VM.
CI has been configured and locally exercised; no remote CI run is claimed here.
