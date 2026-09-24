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

## Usability follow-up — 2026-09-23

The retained interactive workspace was checked again against the same native
macOS smolvm 1.17.0 worker and PostgreSQL 17. The Codex internal browser verified
section navigation, the default collection path, terminal input/output, explicit
disconnect confirmation, clean shell exit, and desktop/390px layouts. The narrow
page had no horizontal overflow and the browser recorded no console errors.

A headless Chromium test accepted the unload prompt and refreshed an active
terminal. The app reconnected to the existing PTY: a shell-local variable retained
its value and the shell PID remained `10`. `exit` then produced confirmed code 0.
This tests browser reconnection with a live controller, not controller restart or
worker PTY recovery. The same test confirmed that stop/start receipts reach
Completed and that collecting `/app/project/index.html` preserves the selected
path. The machine was left running with no active shell for continued testing.

The expanded application suite has 22 passing tests with PostgreSQL and simulated
worker/terminal peers. New coverage checks live-consumer exclusion, unauthorized
input/close/ack rejection, pending-frame delivery on reconnect, stale timers,
reconnect expiry, late reconnect rejection, matching lifecycle receipt versions,
path preservation, and removal of stale terminal warnings after recovery.
Formatting, compilation with warnings as errors, and the asset build passed.
An independent static review found no actionable correctness issues. Linux live
qualification and prolonged network-outage behavior were not rerun in this pass.

One intermediate run had a transient store error while restarting the controller
in the sandboxed test; the same seed passed on rerun. The test now also waits for
the completed command's machine slot to be released before shutting down. This
matches the example's documented clean restart procedure.

## Browser bug fixes — 2026-09-24

A separate disposable workspace was tested with the **Codex internal browser**,
PostgreSQL 17 and the native macOS smolvm 1.17.0 worker. The retained user workspace
and its files were not used for destructive tests.

- Clicking an actual 2 MiB download link while a PTY was attached preserved the
  live page and shell input/output (`still-connected`, shell PID `7`). The downloaded
  bytes matched SHA-256 `91d3beb88a9b2f778a6c44a1c53b63d3c79931845a9aef84b3fb414610bd1938`.
- Reload restored a submitted custom command, `/home/dev` working directory and
  45-second timeout. Unchanged resubmission kept the original request; a separate
  `wc -l` command confirmed exactly one appended line.
- `/etc` as a working directory returned an explicit validation message with no
  prepared/unresolved receipt. Selecting the artifact sample restored `/app/project`
  and wrote the file there.
- Missing and 16 MiB + 1 byte files showed **Failed / Exit 1**, useful diagnostics,
  no download link, and an available machine afterward. Reserved staging-path
  collection was rejected before dispatch.
- Exactly 16 MiB collected and downloaded successfully, with SHA-256
  `a06c26cbac8b80704f420222dae5658b88ff2da96702d12ef7a4223e9361f7c1` matching the
  generated input. The chosen collection path survived a full page reload.
- **Cancel command…** showed the recovery consequence before cancellation.
  **Keep waiting** let the real 20-second command complete normally.
- A real terminal was left beyond its 30-second reconnect window. Reopening showed
  an unknown outcome, disabled terminal entry and recovery instructions, with no
  remaining promise to reconnect.
- Desktop and 390px terminal layouts were inspected; the narrow document measured
  390px with no horizontal overflow. Temporary viewport overrides were reset.

The application suite now has **33 passing tests**. It adds invalid-directory
receipt checks, authorized form restoration, failed-collection slot release,
reserved-path rejection, compatibility with existing collection identities,
recovery copy and download-link behavior. Local Python tests execute the actual
snapshot program against binary, empty, oversized, missing, directory, FIFO and
symlink cases; these are not VM evidence. The worker transport in ExUnit is still
simulated. The repository suite also passed **362 checks** with 28 runtime checks
excluded. App formatting, warnings-as-errors compilation, asset build, script
syntax and diff-whitespace checks passed. An independent review caught the
reserved staging-path collision; both upload and collection now reject it.

The walkthrough uses the current **Disconnect…** label and an actual download
click, rather than only an HTTP client fetch. The entire two-phase script and
Linux live campaign were not repeated for this fix pass. No public library API,
package version or database schema changed; existing durable history remains.

After the expiry check, the disposable controller was stopped, the recorded owned
incarnation was stopped, and the dedicated worker listener was fully stopped and
restarted to drain old requests. Explicit quiesced resolution retained the unknown
execution history. Final deletion verified absence and released all capacity;
the independent worker inventory returned `{"machines":[]}`. The
[final durable record](evidence/fixes-deleted-store.txt) was exported before the
lab app, worker and PostgreSQL were stopped. The user's original app was restarted
with these fixes at `localhost:4005`, with the same retained machine and no active
terminal. Its browser reported no JavaScript errors after reload.
