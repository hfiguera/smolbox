# Saved state walkthrough validation

Validated on September 27, 2026 against the **published SmolBox 0.3.0** package
and **smolvm 1.19.0** on a physical Linux x86_64 worker, using PostgreSQL 16.15,
Elixir 1.20.4 and Erlang/OTP 29.0.6. The Phoenix app ran on Linux; the internal
browser accessed it over a loopback SSH tunnel.

This report covers the new saved state walkthrough. The earlier
[workspace validation](validation.md) remains historical evidence for the
original application. No new macOS guest qualification is claimed.

## Real worker results

The browser created an original from an approved idle bare checkpoint, started
it, and prepared a file on disk plus a note in `/dev/shm`. It captured a new
checkpoint, waited for operator confirmation that the capture request and helper
work were quiescent, and created a branch of the running original. The branch
changed both values. Two separate tracked commands then read the actual guests:

| Original | Branch |
| --- | --- |
| `Original recipe: basil and lemon` | `Branch recipe: ginger and lime` |
| `Prepared in memory` | `Changed in branch memory` |

The downloaded capture was **35,066,590 bytes**, with SHA-256
`25437ad5815b31b75cde7201aa953c954df86bfcd736c3aedb7d3a6981cb16a6`.
A controller restart recovered the same machine identities, capture result,
branch lineage and command outputs from PostgreSQL. No command was replayed.
This scenario did not restore a new guest from the downloaded capture; the
branch comes from the running original, not from that file.

The everyday workspace was then created alongside the original and branch. Its
Python startup service returned HTTP content, and its default command completed
with exit code zero. This was a coexistence smoke check, not a repeat of the
complete terminal, file transfer and long command qualification campaign.

## Cleanup and accounting

The app was stopped before cleanup. Cleanup called the same `Workspace.SavedState`
actions used by the UI. Host checks established request quiescence before the
explicit confirmations. Guest deletion, branch retirement, backing release and
checkpoint release remained separate operations.

| Observed phase | Slots | CPUs | Memory MiB | Disk GiB |
| --- | ---: | ---: | ---: | ---: |
| Original, branch and capture retained | 3 | 3 | 3072 | 13 |
| Everyday workspace also running | 4 | 4 | 4096 | 17 |
| Branch deleted, backing still retained | 3 | 3 | 3072 | 15 |
| All three guests deleted | 1 | 1 | 1024 | 9 |
| Host cleanup confirmed, all reservations released | 0 | 0 | 0 | 0 |

These are conservative store reservations, **not measured physical usage**.
After guest deletion, the worker machine list was empty, its service cgroup had
no VM/helper processes, owned machine backing directories were absent and worker
scratch was empty. Shared runtime caches and the approved seed were preserved.
The captured file was explicitly removed after inspecting its path and digest;
there were no other complete or partial capture files in the isolated lab.
Only then were backing and capture reservations released. Durable records and
request identities remain. The worker logged a retained UID assignment warning
on deletion; zero SmolBox reservations does not claim reclamation of every
upstream host bookkeeping entry.

[Sanitized observed records](saved-state-evidence.json) preserve machine and
execution identities, outputs, lifecycle states and accounting at each stage.
They omit private configuration and host paths.

## Simulated and static coverage

The example's **42 tests passed** against a local PostgreSQL 17.7 test database.
Worker and terminal transports in these tests are simulated. New tests cover the
complete saved state flow, controller restart, conflicting actions, concurrent
preparation deduplication, lost capture and branch responses, server-side
confirmation requirements, unavailable runtime/store, retained cleanup budgets,
and legacy settings that must retain their 1.17.0 worker pin. Existing everyday
workspace tests run in the same suite.

Formatting, compilation with warnings as errors, strict Credo with ExSlop,
ExDNA and Dialyzer passed. Frontend dependencies installed and assets built.
Browser review covered the new section at desktop and 390-pixel mobile widths,
including real comparison output, retention rows and expanded cleanup controls.
The independent finish review's destructive-control finding was fixed and its
follow-up verdict was `ship` for that fix.

The deliberate lost-response and unavailable-store cases are simulated evidence;
they were not injected into the real Linux campaign. The example is one bounded
walkthrough per private configuration, not a general checkpoint browser or a
host cleanup automation service.
