---
name: SmolBox engineering blog
description: A technical field guide with open reading layouts and geometric execution diagrams.
colors:
  paper: "#fbfcfe"
  ink: "#17304e"
  muted: "#526478"
  accent: "#215bc7"
  accent-hover: "#16479f"
  line: "#d8e0eb"
  wash: "#edf2fa"
  code: "#1f2937"
  amber: "#86510f"
  code-text: "#e7ecf4"
  white: "#fff"
typography:
  display:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "64px"
    fontWeight: 700
    lineHeight: 1.17
    letterSpacing: "-.04em"
  headline:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "52px"
    fontWeight: 700
    lineHeight: 1.17
    letterSpacing: "-.03em"
  title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "30px"
    fontWeight: 700
    lineHeight: 1.17
    letterSpacing: "-.03em"
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "18px"
    fontWeight: 400
    lineHeight: 1.7
  label:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.7
  code:
    fontFamily: 'ui-monospace, "SFMono-Regular", Consolas, monospace'
    fontSize: "14px"
    lineHeight: 1.7
rounded:
  inline-code: "3px"
  control: "4px"
  panel: "8px"
spacing:
  space-8: "8px"
  space-12: "12px"
  space-16: "16px"
  space-24: "24px"
  space-28: "28px"
  space-32: "32px"
  space-48: "48px"
components:
  copy-code:
    backgroundColor: "{colors.code}"
    textColor: "{colors.code-text}"
    rounded: "{rounded.control}"
    padding: "4px 11px"
  action-link:
    textColor: "{colors.accent}"
    padding: "8px 0"
  action-link-hover:
    textColor: "{colors.accent-hover}"
  code-block:
    backgroundColor: "{colors.code}"
    textColor: "{colors.code-text}"
    typography: "{typography.code}"
    rounded: "{rounded.panel}"
    padding: "46px 24px 24px"
---

# Design System: SmolBox engineering blog

## Overview

**Creative North Star: "Technical field guide"**

The blog uses cool white paper, navy text, clear rules, and geometric diagrams
to make engineering explanations easy to follow. Headings establish a strong
reading order; the surrounding layout stays open and quiet. This is a Read
surface, using the platform sans stack for both headings and prose.

This record describes the implemented blog. Its source of truth is
`assets/site.css`, the EEx templates, `assets/site.js`, and the editable SVGs.
The token frontmatter records shared values; the companion
`.impeccable/design.json` records states, breakpoints, and component previews.
Both files are development notes under `docs/blog/`, outside the public asset
directories. Update them together when the implemented system changes.

**Key Characteristics:**

- Open layouts with a bounded prose measure and a desktop contents rail.
- Navy hierarchy, cobalt navigation, and amber caveats.
- Flat surfaces with crisp rules and small, functional corner rounding.
- Original diagrams, readable code, and progressive enhancement.

## Colors

Cool neutrals carry the page; cobalt identifies actions and diagram connections,
while amber gives caveats a separate semantic role.

### Primary

- **Cobalt** (`accent`): links, the outline brand mark, focus outlines, and diagram
  connectors or execution nodes. **Deep cobalt** (`accent-hover`) is the link
  hover state.
- **Caveat amber** (`amber`): caution text on a pale amber blockquote surface.
  Its purpose is to distinguish limitations from the surrounding explanation.

### Neutral

- **Cool paper** (`paper`): the page background across every route.
- **Navy ink** (`ink`): body text, headings, project navigation, and the host node
  in lifecycle diagrams.
- **Slate** (`muted`): descriptions, dates, captions, and secondary navigation.
- **Fine rule** (`line`): structural separators and table rows.
- **Blue wash** (`wash`): inline code, table headers, and diagram grounds.
- **Code charcoal** (`code`) and **code text** (`code-text`): fenced examples
  and their copy controls. Syntax colors come from Makeup's generated
  `one_dark_style` stylesheet scoped to `.makeup`, matching the emitted code
  element class, rather than a separate blog token scale.
- **White** (`white`): reversed text and the diagrams' light worker node.

**The Structural Color Rule.** Use the shared palette to distinguish text,
actions, code, diagrams, and caveats. Preserve those roles when adding content.

## Typography

**Display and Body Font:** the platform sans stack in the frontmatter.
**Code Font:** the system monospace stack in the frontmatter.

The same sans family connects the title, navigation, and prose. Scale, weight,
and spacing provide hierarchy; there are no downloaded font files. The system
stack is an intentional fit for this Read surface.

### Hierarchy

- **Display:** index title, with the largest size and tighter tracking.
- **Headline:** article title; utility-page titles use a smaller size (46px).
- **Title:** article H2. H3 is smaller (23px); index article titles are slightly
  larger (32px). Headings share balanced wrapping and tight line height.
- **Body:** long-form prose. Introductions and article decks are larger (21px),
  while index summaries are smaller (17px). The article deck has a tighter
  line height (1.55).
- **Label:** publication metadata. Contents and captions use a slightly larger
  size (14px); project navigation uses (15px). Labels remain in normal case.
- **Code:** fenced examples retain a stable size across breakpoints. Inline
  code scales with its surrounding text (.86em).

This is a role-based ramp, not a mathematical type scale. Responsive title and
body sizes are listed below; they are explicit steps rather than fluid clamps.

## Layout

The main shell is centered with a maximum width (1184px) and desktop side space
(40px each). The index uses a two-column introduction, followed by open article
entries pairing the diagram with its title, metadata, summary, and link.

Articles use a contents rail (216px), a column gap (48px), and a prose column
bounded by `--reading-width` (70ch). The article header and next-step section
align with the prose through a left offset (264px). The contents rail stays
sticky near the top (28px). Privacy and 404 pages use one centered reading
column with side space (24px each).

Paragraph spacing follows the text size (1.4rem); section breaks are more
generous than gaps between related controls or metadata. Reuse the observed
spacing steps in the frontmatter without treating every margin as a new token.

| Maximum viewport width | Implemented change |
| --- | --- |
| 1050px | Index title becomes 52px; article title becomes 44px; contents rail becomes 192px with a 32px gap and 224px prose offset. |
| 800px | Main shell uses 20px side space; index and article grids become one column; contents loses stickiness and uses two list columns; footer stacks; index title becomes 48px. |
| 600px | The article's lifecycle figure selects its separate vertical SVG composition. |
| 480px | Body becomes 17px; index title becomes 40px; article title becomes 38px; deck becomes 19px; article H2 becomes 28px; contents becomes one list column; header navigation wraps onto its own row. |

**The Reading Measure Rule.** Keep prose bounded and let long code and tables
scroll inside their own containers. A wide example must not widen the page.

## Elevation & Depth

There are no box shadows. Background changes separate code, caveats, and
diagrams; thin rules separate site regions, contents, and table rows. Depth is
flat and structural. Hover states change color or underline, with a small arrow
movement on forward article and next-step links.

## Shapes

Page regions and article entries have open edges. Rounded corners belong to
contained material: inline code, copy controls, code panels, caveats (6px), and
diagram nodes. Structural borders are thin (1px). The brand is an outlined box;
directional link icons are inline SVG paths with round line caps and joins.

## Components

### Navigation and links

The header pairs the box mark and wordmark with text links. Current-page and
hover states use cobalt and underlining. The footer repeats text navigation at
a smaller scale. The focused skip link becomes visible at the upper left and
targets the main content.

Article action links are bold and underlined, with decorative SVG arrows.
Forward arrows move right (4px over .18s, ease-out) on hover. Global keyboard
focus uses a cobalt outline (3px) with an offset (5px). Reduced-motion mode
removes transitions and switches smooth scrolling to immediate scrolling.

### Article entries and metadata

Entries are unboxed image-and-text compositions. Title links use navy at rest,
then cobalt and an underline on hover. Dates, reading time, and category wrap
as compact metadata. Articles place the author name and explicit X/GitHub profile
links in a wrapping row above the date, reading time, and release version.
Each profile link pairs `@hfiguera` with a 16px inline SVG logo, separated by 6px.
Logos inherit the link color and are decorative to assistive technology. The
accessible label includes the author, platform, and visible handle; a title
also identifies the platform on hover.
Keep the title link as the accessible image destination: the duplicate
decorative image link is hidden from assistive technology and the tab order.

### Contents

The section list is a native, initially open `details` element with a bold
summary. Links use slate at rest and cobalt with an underline on hover or
keyboard focus. Its list contains article H2 headings. Preserve native collapse
behavior and the responsive placement described in Layout.

### Code examples and copy controls

Fenced code is a dark panel with extra top space for its small bordered copy
button. Horizontal scrolling preserves long lines. On phones, horizontal panel
padding narrows (16px). Inline code uses blue wash and can wrap long identifiers.

JavaScript adds copy controls only when the Clipboard API is present. Success
shows “Copied”; a failed write selects the code and shows “Select code”. A live
status region announces the outcome, and the label resets after 2.5 seconds.
Copy-button hover lightens its background; its focus outline becomes pale blue
for contrast against the panel. Reading and section navigation work without
JavaScript, and copy actions are not analytics events.

### Caveats and tables

Caveats use a pale amber fill with amber text and inset space (20px vertically,
24px horizontally). Tables use washed header cells, fine row rules, tabular
numbers, and horizontal scrolling. Neither pattern adds a shadow.

### Lifecycle diagrams

The visual language is authored geometry: navy host, light worker, cobalt VM,
and directional connectors on blue wash. The article supplies meaningful image
alternative text and a caption; the index thumbnail is decorative beside its
linked title. Keep the mobile SVG composition separate so labels stay readable.
The editable sources and PNG provenance are recorded in `media-provenance.md`;
preserve those records when updating the article raster or social fallback.

## Do's and Don'ts

### Do:

- **Do** reuse the palette roles and the platform sans/monospace pairing.
- **Do** preserve the reading measure, prose alignment, and responsive contents.
- **Do** keep section navigation, focus indicators, and content usable without JavaScript.
- **Do** use inline SVG for directional icons and preserve meaningful diagram descriptions.
- **Do** update this record and its sidecar after visual changes, then inspect desktop and mobile pages using the checks in `README.md`.

### Don't:

- **Don't** turn open article entries into elevated cards; the current system uses rules and space.
- **Don't** use amber for ordinary links or decorative emphasis; it identifies caveats.
- **Don't** shrink the desktop lifecycle diagram into unreadable mobile labels.
- **Don't** copy design notes into `assets/` or `media/`; both directories are published in full.
