# Blog asset provenance

## Article motion figures — September 19, 2026

The checkpoint, lifecycle and cleanup `*-motion.mp4` videos and matching PNG
posters are original diagrams rendered locally with Pillow
and ffmpeg, using the blog palette and locally installed Arial / Andale Mono.
No fonts are distributed. Each sequence is 960 × 540, 25 fps, nine seconds.
The checkpoint sequence shows a local edit in Job A, an unchanged source and
Job B, and a later Job C restore from the original table. The table cells are
schematic, not a new runtime experiment.
Timings and storage cells are illustrative, not measurements. Generation scripts
and original GIF experiments remain in the local `motion-examples/` workspace,
which is intentionally excluded from the repository.

`checkpoint-preparation-mobile.svg` and `lifecycle-motion-mobile.svg` are original
vertical diagrams. Cleanup reuses `deletion-order-mobile.svg` on phones.
The article figures use manual playback, static posters, readable mobile SVGs,
and mobile video links. No third-party artwork was added.

## Checkpoint preparation article

Original SVG geometry uses the existing blog palette. One approved idle source
supplies the starting state for three separate executions. The composition
illustrates the lifecycle; it is not a timing chart or a live branching claim.

- `media/prepare-once-run-in-a-fresh-vm/checkpoint-preparation-social.svg`:
  editable 1200 × 630 artwork for sharing.
- `media/prepare-once-run-in-a-fresh-vm/checkpoint-preparation.png`:
  Chromium rasterization of that SVG for article cards and social metadata.

The article cites the published 0.1.5 checkpoint evidence and scripts. No new
measurements, external artwork or reader identities are introduced.

The lifecycle artwork is original, repository-authored geometry. It depicts the
Elixir application, SmolBox, a smolvm worker, and a disposable Python VM. It is a
conceptual architecture diagram, not a runtime trace or benchmark.

| Asset | Origin |
| --- | --- |
| `media/running-python-from-elixir-with-smolbox/execution-lifecycle.svg` | Editable desktop diagram, authored as SVG at 1200 × 630. |
| `media/running-python-from-elixir-with-smolbox/execution-lifecycle-mobile.svg` | Separate vertical SVG composition at 390 × 706 for readable mobile labels. |
| `media/running-python-from-elixir-with-smolbox/execution-lifecycle.png` | Chromium rasterization of the desktop SVG at 1200 × 630 for article cards and social metadata. |
| `assets/social.png` | Identical raster used as the site-wide social fallback. |
| `assets/favicon.svg` | Original outline box mark, reused in the site header. |
| X and GitHub logos in `templates/article.html.eex` | Paths from [Simple Icons](https://github.com/simple-icons/simple-icons/tree/777807a262bb7384ff406fd4b35fdcd02e9514c3), rendered as decorative 16px inline SVGs with visible link labels. |

The profile logos come from [`icons/x.svg`](https://github.com/simple-icons/simple-icons/blob/777807a262bb7384ff406fd4b35fdcd02e9514c3/icons/x.svg)
and [`icons/github.svg`](https://github.com/simple-icons/simple-icons/blob/777807a262bb7384ff406fd4b35fdcd02e9514c3/icons/github.svg),
under Simple Icons' [CC0 license](https://github.com/simple-icons/simple-icons/blob/777807a262bb7384ff406fd4b35fdcd02e9514c3/LICENSE.md).
Only the two paths are included; no icon font, package, or remote asset request
is required to display them.

No stock imagery, generated photography, or third-party font files are included.
The lifecycle PNG files carry their origin in a PNG text chunk. Keep editable SVG sources
and this record when replacing the raster. Do not copy this development note
into `media/` or `assets/`, which are public output directories.

## Nested KVM case study

These diagrams are original, repository-authored SVG geometry using the existing
navy and cobalt palette. They depict the recorded Linux deployment conceptually;
they are not screenshots of a running VM or a security certification. Budgets
refer to the layer labelled in the diagram. The article explains the distinction
between host limits, guest allocations and recovery deadlines.

| Asset | Origin |
| --- | --- |
| `media/testing-smolbox-with-nested-kvm/nested-lab.svg` | Editable desktop deployment diagram at 1200 × 780. |
| `media/testing-smolbox-with-nested-kvm/nested-lab-mobile.svg` | Vertical composition at 390 × 824 with readable mobile labels. |
| `media/testing-smolbox-with-nested-kvm/nested-lab-social.svg` | Simplified 1200 × 630 composition for article cards and social previews. |
| `media/testing-smolbox-with-nested-kvm/nested-lab.png` | Linux Chromium rasterization of `nested-lab-social.svg`, at 1200 × 630. |

## Upstream cleanup follow-up

Original SVG geometry using the existing blog palette. The article diagrams
simplify the HTTP deletion ordering changed in smolvm PR #1219. The social
composition illustrates the collaboration, not a runtime trace. No portraits,
social screenshots or third-party artwork are included.

| Asset | Origin |
| --- | --- |
| `media/from-a-full-disk-to-an-upstream-fix/deletion-order.svg` | Editable desktop sequence comparison at 1200 × 520. |
| `media/from-a-full-disk-to-an-upstream-fix/deletion-order-mobile.svg` | Vertical comparison at 390 × 670 for readable mobile labels. |
| `media/from-a-full-disk-to-an-upstream-fix/upstream-cleanup-social.svg` | Original 1200 × 630 composition for article cards and sharing. |
| `media/from-a-full-disk-to-an-upstream-fix/upstream-cleanup.png` | Chrome rasterization of `upstream-cleanup-social.svg`, at 1200 × 630. |

## Controlled network access article

The new diagrams are original SVG geometry using the existing blog palette.
They show approved configuration, recorded execution, runtime enforcement,
collection and cleanup. They are conceptual diagrams, not packet traces.

- `media/controlled-network-access-from-elixir/network-policy.svg`: desktop diagram.
- `media/controlled-network-access-from-elixir/network-policy-mobile.svg`: separate
  mobile composition with readable labels.
- `media/controlled-network-access-from-elixir/controlled-network-social.svg`:
  original 1200 × 630 social artwork.
- `media/controlled-network-access-from-elixir/controlled-network.png`: Chromium
  rasterization of that SVG for article cards and social metadata.

The same public directory contains `network-report.exs`, the runnable example,
and `observed-run.json`, its sanitized ordinary macOS execution evidence. The
JSON identifies the published library, worker version, artifact digest and source
script digest, plus the retrieved public USGS feed's timestamp and content hash.
It contains no account credentials or private host paths. It records a successful
application example, not an additional isolation qualification.

## Nested KVM performance comparison

Original SVG geometry reuses the blog's navy and cobalt palette. The diagram
shows the two measured deployment layouts, with separate desktop and mobile
compositions. It is a conceptual diagram rather than a trace or security claim.

- `media/measuring-nested-kvm-overhead/comparison.svg`: desktop comparison,
  1120 × 580.
- `media/measuring-nested-kvm-overhead/comparison-mobile.svg`: vertical mobile
  comparison, 390 × 800.
- `media/measuring-nested-kvm-overhead/nested-performance-social.svg`: original
  1200 × 630 sharing composition. Its startup figures are medians from the
  six measured pairs in the accompanying evidence.
- `media/measuring-nested-kvm-overhead/nested-performance.png`: Chromium
  rasterization of that SVG, for article cards and social metadata.
- `media/measuring-nested-kvm-overhead/measurements.json`: byte-identical public
  copy of `docs/evidence/nested-kvm-performance.json`. It includes the measured
  samples, warmups, methodology metadata, checksums and teardown observations.
  Synchronize the public copy if the source evidence changes.

No social screenshot, reader identity, external artwork or generated photograph
is included. The reader's question is paraphrased from feedback supplied by the
maintainer; the post does not attribute a name that was not provided.


## Recovery, network controls, and performance motion figures

Added `recovery-motion.mp4` / `.png`, `network-motion.mp4` / `.png`, and
`performance-motion.mp4` / `.png` to their matching article media directories.
All are original nine-second, 960 × 540 sequences rendered locally,
with manual playback. The recovery and
network figures use Pillow geometry; the performance plot uses matplotlib and
reads the committed measurement JSON, validating summary statistics against the
raw samples. No new runtime tests or measurements are represented.

The recovery/network mobile SVGs are original vertical diagrams. The performance
mobile SVG is exported from the same matplotlib/data source. DejaVu Sans glyph
outlines preserve the chart typography; no font file is distributed.
Evidence sources, relative to the repository root:

- Recovery: `docs/evidence/nested-kvm-lab.json` (`checks.recovery`),
  `scripts/lab/recovery-sweep.sh`, and `scripts/lab/verify-recovery.sh`.
  Automatic disk rebuilding and explicit validation boot are separate steps;
  the figure does not imply command replay or preservation of records in the lost VM.
- Networking: `docs/network-access.md` (Validation),
  `docs/evidence/controlled-network-access.json` (`network_observations`), and
  `scripts/lab/network-access.sh`. A/B are schematic synthetic responder labels.
  Moving dots are conceptual connections, not recorded packets or enforcement locations.
- Performance: `docs/blog/media/measuring-nested-kvm-overhead/measurements.json`,
  using `statistics.ready_ms` and `statistics.cpu_guest_ms`, checked against all
  six raw samples per configuration. Range lines show observed min–max, not
  confidence intervals. Overlap does not establish equivalence or a speedup;
  the deployment comparison does not isolate nesting overhead.

Existing architectural diagrams and social images are unchanged.


## Persistent workspace — September 24, 2026

- `media/build-a-persistent-workspace/lifecycle.svg` (1120 × 510) and
  `lifecycle-mobile.svg` (390 × 690) are original geometric diagrams of command,
  controller and machine lifetimes. Their arrows describe workflow, not timing.
- `persistent-workspace-social.svg` is an original 1200 × 630 composition using
  the existing blog colors and platform-compatible sans typography.
  `persistent-workspace.png` is its local Sharp rasterization. No external
  illustration, photograph or generated image is included.
- `workspace-demo.mp4` is a silent, 32-second edited walkthrough, assembled with
  FFmpeg from eight real internal-browser captures of a fresh, isolated macOS
  demo. Each capture is held four seconds and has an editorial heading outside
  the app image. The service capture is proportionally fitted to the same frame;
  app content is not altered. Output is 1200 × 880 at 24 fps. This is not a
  continuous recording and makes no startup or performance claim.
- `workspace-demo.png` is the first composed frame. Native playback and seeking
  remain available; mobile readers get the vertical lifecycle diagram and an
  explicit video link. Nothing autoplays.
- `walkthrough-evidence.json` records the observed results: successive commands,
  downloaded bytes, the article API snippet against Hex 0.2.0, controller
  restart, machine stop/start, and deletion with an empty worker and zero usage.
  This bounded observation record is not a raw log or an automated test report.

The captures contain only a new demo identity and authored project fixtures.
The user's existing workspace, files, private configuration and keys are absent.
The isolated demo machine was explicitly deleted, then its controller, worker
and database processes were stopped. Linux app qualification was not performed.

## Application readiness — September 25, 2026

- `media/running-vm-ready-application/readiness-social.svg` is an original
  1200 × 630 geometric composition. `readiness.png` is its local Sharp
  rasterization, with origin metadata embedded. No external imagery or
  generative image model was used.
- The article's inline HTML/SVG figure and CSS/JavaScript animate two authored
  scenarios: a service warming up and a missing startup executable. The moving
  request and response marks explain observations; they are not packet captures,
  timing measurements or a screen recording. The caption states this distinction.
- Playback starts only on request, ends after one sequence, and has Pause,
  Replay and manual stepping controls. Offscreen and hidden documents pause it.
  Reduced motion removes spatial transitions and packet motion. Without
  JavaScript, the final static explanation remains visible and controls stay hidden.
- `readiness.exs` runs three live scenarios using the repository's durable host
  helpers. `validation.json` records their native macOS worker observations,
  environment, script digest, preflight corrections and evidence limits.
  All three final cases verified deletion and reservation release. Both working
  services returned 503 before the expected 200, rejected the wrong instance,
  and retained the startup counter across VM stop/start. The missing executable
  left the VM running; a separate safe diagnostic execution returned 127.

The fixture contains no user project data or private credentials. This article
extends the existing blog visual system and introduces no external runtime assets.
