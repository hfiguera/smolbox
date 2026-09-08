# SmolBox engineering blog

<!-- impeccable:product-schema 1 -->

## Platform

web

This record applies to the static blog. SmolBox itself is an Elixir library.

## Stack

Elixir-generated static HTML and CSS, Markdown articles, GitHub Pages hosting,
and Cloudflare Web Analytics, following the Obscura approach approved by the
maintainer on September 7, 2026. HexDocs remains the reference documentation.

## Users and purpose

Elixir developers evaluating a way to run Python, JavaScript, and other programs
on self-hosted SmolVM workers. Help readers decide when that architecture fits,
understand what Smol Machines supplies and what SmolBox adds, and follow a real
integration with the limits of the current release explicit.

## Capabilities and constraints

SmolBox 0.1.0 supports the pinned SmolVM 1.14.1 worker API. Its release is tested
for development use on Linux x86_64/KVM and macOS Apple Silicon. It does not
certify production isolation for hostile code or hard host resource quotas.
The application operates workers, supplies approved images, and chooses storage.

## Brand commitments

Use the SmolBox name. Write concrete engineering explanations and show actual
APIs. The maintainer approved a distinct visual identity from Obscura; the initial
direction is cool white, navy, and cobalt, with amber reserved for caveats.

## Evidence on hand

The 0.1.0 public source and HexDocs, the complete getting-started walkthrough,
minimal and PostgreSQL host examples, and release-candidate validation records.
There are no supplied customer testimonials or production certification claims.

## Product principles

- Teach with working integrations and explicit prerequisites.
- Keep observed results, uncertain outcomes, and cleanup distinct.
- Publish article dates and the version each example describes.
- Keep content readable without JavaScript or analytics.
