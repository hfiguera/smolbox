# Maintaining the SmolBox blog

The blog is a static site generated with Elixir, EEx, ExDoc's Markdown renderer,
and Makeup. Its public address is <https://hfiguera.github.io/smolbox/>. HexDocs
remains the API reference and versioned getting-started documentation.

## Build and preview

Run these commands from the repository root with the versions in `.tool-versions`:

```sh
mise install
MIX_ENV=dev mise exec -- mix deps.get
MIX_ENV=dev mise exec -- mix run --no-start scripts/build_blog.exs
MIX_ENV=dev mise exec -- mix run --no-start scripts/verify_blog.exs
MIX_ENV=dev mise exec -- mix run --no-start --no-halt scripts/preview_blog.exs
```

Open <http://127.0.0.1:4173/smolbox/>. Stop the preview with Ctrl+C.
The preview binds only to loopback and preserves the deployed `/smolbox/` prefix.
It does not send analytics unless the site was explicitly built with `--analytics`.

The builder refuses to overwrite a nonempty output directory. Before rebuilding,
remove the generated `_site/` directory, or use a fresh directory with
`--output /path/to/empty-directory` on both build and verification commands. The
preview script serves `_site/`. Generated output is ignored by Git.

## Add an article

1. Add one entry to `articles.json`. Required fields are `slug`, `title`,
   `description`, `published_on`, `updated_on`, `version`, `category`, `image`, and
   `image_alt`. Use ISO dates, a unique lowercase hyphenated slug, and the SmolBox
   version actually used by the example. The manifest supplies titles, metadata,
   cards, article order, RSS, sitemap, and social previews.
2. Write `<slug>.md` beside the manifest. Begin with prose; the template supplies
   the H1. Use H2 and H3 headings for navigation, fenced code blocks, and versioned
   documentation links. State prerequisites before commands and distinguish
   observed results from unsupported guarantees.
3. Put public images in `media/<slug>/`. The manifest image must be a PNG smaller
   than 500 KB. Use 1200 × 630 for social sharing. Include meaningful alternative
   text. Diagrams may use separate desktop and mobile SVGs in a `<picture>`;
   avoid shrinking desktop labels until they are unreadable on phones.
4. Record asset origins in `media-provenance.md`. Put only public assets in
   `assets/` and `media/`: these directories are copied to the output in full.
5. Build, verify, preview, and run the checks below. Keep `published_on` stable
   after publication; advance `updated_on` when making substantive corrections.

The initial article follows the released `examples/minimal_host` walkthrough.
Check executable examples against the release named in the article. Do not turn
development qualification into a production isolation claim.

Fenced examples currently support `elixir`, `sh`, and `bash`. Elixir uses its
native Makeup lexer; shell examples use MakeupSyntect. Highlighting happens at
build time, so reading highlighted examples requires no JavaScript. These
highlighters are development/test dependencies, including a precompiled native
lexer; they are not dependencies of the published library. Generate the theme
with the `makeup` CSS scope used by ExDoc's HTML. When adding another language,
register its lexer and check rendered token colors, not just the presence of a
code block.

## Validation

```sh
MIX_ENV=test mise exec -- mix test test/unit/blog_test.exs --warnings-as-errors
MIX_ENV=test mise exec -- mix ci
```

The verifier checks local destinations and section fragments, metadata,
canonical URLs, heading IDs, media, feeds, and the expected analytics mode. The
verification script also parses RSS and sitemap XML with OTP's `xmerl`. Tests
exercise rejected metadata, broken navigation, output preservation, and both
analytics modes. These are maintainer tools under `dev/` and `scripts/`; they are
excluded from the Hex package and production compilation.

After visual changes, inspect the index, article, privacy, and 404 pages at desktop
and mobile widths. Check keyboard focus, the skip link, contents navigation,
code copying, long code/table scrolling, reduced motion, and reading without
JavaScript. Automated accessibility checks support this inspection; they do not
replace it. External links need a separate live check.

## Publishing

`.github/workflows/blog.yml` builds and verifies the site for relevant branch
pushes and pull requests. Only `main` can run its deployment job. That job deploys
the verified `_site/` artifact through GitHub Pages; it does not modify a generated
branch or publish a Hex release. A manual workflow run on `main` can redeploy it.

GitHub Pages is configured to use GitHub Actions with HTTPS. Merge the reviewed
blog branch into `main`, check that both workflow jobs pass, and then verify the
public index, article, privacy page, 404, RSS, sitemap, and social image. Source
and design notes stay in Git; only generated HTML, feeds, and public assets ship.

## Tracking

The production workflow passes `--analytics` to both build and verification.
Each page receives exactly one Cloudflare Web Analytics beacon. The public
browser token in `dev/smolbox/blog.ex` is the existing `hfiguera.github.io`
property used by the Obscura blog. It is an identifier, not an API credential.

In Cloudflare Web Analytics, select that hostname and filter the Path dimension
for `/smolbox/` and `/smolbox/blog/…` to inspect SmolBox traffic. The property is
shared across projects; hostname totals alone do not isolate this blog. A
separate property would require a separate hostname and corresponding site
configuration. See Cloudflare's [setup guide][analytics-setup] and
[filter dimensions][analytics-dimensions].

This configuration measures visits, referrers, and performance. It does not
measure library installation or adoption. Cloudflare does not support custom
events or log URL query strings in this product, so UTM attribution and copy
events are not part of this setup. See the [Web Analytics FAQ][analytics-faq].
The site includes a public privacy explanation and remains usable if the beacon
is blocked.

After the first deployment, verify one real visit in the browser network panel
and confirm the corresponding path in the Cloudflare dashboard. A successful
build or beacon download is not evidence that dashboard ingestion worked. Local
verification has checked the script configuration; dashboard receipt remains a
post-deployment check.

[analytics-setup]: https://developers.cloudflare.com/web-analytics/get-started/
[analytics-dimensions]: https://developers.cloudflare.com/web-analytics/data-metrics/dimensions/
[analytics-faq]: https://developers.cloudflare.com/web-analytics/faq/

## Design maintenance

`PRODUCT.md` records the blog's audience and factual constraints. `brief.md`
records the accepted surface direction, and `DESIGN.md` records the built visual
system. These files are development notes and are not served by the site.
The initial implementation used Impeccable for design review; it is not a build
dependency. There is no Node package, frontend framework, database, or separate
application to operate for the blog.
