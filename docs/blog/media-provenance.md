# Blog asset provenance

The lifecycle artwork is original, repository-authored geometry. It depicts the
Elixir application, SmolBox, a SmolVM worker, and a disposable Python VM. It is a
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
simplify the HTTP deletion ordering changed in SmolVM PR #1219. The social
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
