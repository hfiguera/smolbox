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
