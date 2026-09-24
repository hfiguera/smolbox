---
name: "SmolBox Workspace"
description: "A calm, persistent place for commands, files, and a real shell."
colors:
  paper: "#f5f4ee"
  surface: "#fffef9"
  ink: "#252820"
  muted: "#626657"
  rule: "#dcded2"
  olive: "#d7e69b"
  olive-ink: "#303d14"
  danger: "#993326"
  focus: "#496121"
  button-border: "#b7bcaa"
  button-hover: "#e9ecde"
  primary-hover: "#c8dd7a"
  white: "#fff"
  field-border: "#bfc3b4"
  field-background: "#f7f8f2"
  output-background: "#f1f2eb"
  tools-background: "#f8f8f2"
  state-background: "#edeee7"
  state-ink: "#515648"
  success-background: "#e4edce"
  success-ink: "#3b511c"
  uncertain-background: "#f8e9c9"
  uncertain-ink: "#704700"
  terminal-background: "#22261f"
  terminal-ink: "#eff1e6"
  terminal-muted: "#bfc7af"
typography:
  display:
    fontFamily: "DM Sans Variable, sans-serif"
    fontSize: "clamp(30px, 3vw, 42px)"
    fontWeight: 650
    lineHeight: 1.13
    letterSpacing: "-.035em"
  headline:
    fontFamily: "DM Sans Variable, sans-serif"
    fontSize: "24px"
    fontWeight: 650
    letterSpacing: "-.025em"
  title:
    fontFamily: "DM Sans Variable, sans-serif"
    fontSize: "18px"
    fontWeight: 650
    letterSpacing: "-.015em"
  body:
    fontFamily: "DM Sans Variable, sans-serif"
    fontSize: "14px"
    lineHeight: 1.6
  label:
    fontFamily: "DM Sans Variable, sans-serif"
    fontSize: "12px"
    fontWeight: 550
    lineHeight: 1.5
  command:
    fontFamily: "JetBrains Mono Variable, monospace"
    fontSize: "13px"
    lineHeight: 1.7
  output:
    fontFamily: "JetBrains Mono Variable, monospace"
    fontSize: "12px"
    lineHeight: 1.6
rounded:
  badge: "4px"
  field: "6px"
  control: "7px"
  surface: "12px"
spacing:
  6: "6px"
  8: "8px"
  10: "10px"
  12: "12px"
  14: "14px"
  16: "16px"
  18: "18px"
  20: "20px"
  22: "22px"
  24: "24px"
  26: "26px"
  28: "28px"
  30: "30px"
  32: "32px"
  36: "36px"
  48: "48px"
components:
  button-primary:
    backgroundColor: "{colors.olive}"
    textColor: "{colors.olive-ink}"
    rounded: "{rounded.control}"
    padding: "10px 15px"
  button-primary-hover:
    backgroundColor: "{colors.primary-hover}"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "10px 15px"
  button-secondary-hover:
    backgroundColor: "{colors.button-hover}"
  button-danger:
    backgroundColor: "{colors.danger}"
    textColor: "{colors.white}"
    rounded: "{rounded.control}"
    padding: "10px 15px"
  button-danger-text:
    backgroundColor: "transparent"
    textColor: "{colors.danger}"
    rounded: "{rounded.control}"
    padding: "10px 15px"
  input:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.field}"
    padding: "10px"
    width: "100%"
  command-input:
    backgroundColor: "{colors.field-background}"
    textColor: "{colors.ink}"
    typography: "{typography.command}"
    rounded: "{rounded.field}"
    padding: "16px"
    width: "100%"
  state:
    backgroundColor: "{colors.state-background}"
    textColor: "{colors.state-ink}"
    rounded: "{rounded.badge}"
    padding: "3px 7px"
  workspace:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.surface}"
  service-link:
    textColor: "{colors.ink}"
    padding: "12px 0"
  terminal:
    backgroundColor: "{colors.terminal-background}"
    textColor: "{colors.terminal-ink}"
    rounded: "{rounded.control}"
    padding: "16px"
    height: "320px"
---

# Design System: SmolBox Workspace

## Overview

**Creative North Star: "The Developer Command Launcher"**

Warm paper, compact controls, and a steady typographic hierarchy make this workspace feel like a useful place to work. Olive marks the next action; near-black text and a dark terminal give commands and their results clear visual weight.

The interface uses flat surfaces, fine rules, and restrained corners. Information is dense where evidence matters, with ample separation between working areas. Plain developer language keeps status and uncertainty explicit.

**Key Characteristics:**

- Warm paper and a restrained olive accent.
- DM Sans for interface text; JetBrains Mono for commands, code, and terminal output.
- Flat, ruled working surfaces with modest corners.
- Visible keyboard focus and explicit state labels.

## Colors

The palette is warm, pale, and slightly green, with olive reserved for action and darker tones for evidence. Frontmatter values are normative; the names below describe their application.

### Primary

- **Olive:** the primary action fill and selected text background; olive ink keeps its labels grounded.
- **Deep Olive Focus:** the visible keyboard outline, caret, and service-link hover.

### Neutral

- **Warm Paper:** the outer page background.
- **Ivory Surface:** the workspace, setup surface, and standard controls.
- **Charcoal Ink:** headings, labels, and ordinary interface text.
- **Muted Moss:** supporting copy and secondary metadata.
- **Pale Rule:** structural dividers; separate border tokens give controls a stronger edge.
- **Field, Output, and Tools Tints:** quietly distinguish entry, results, and supporting tools.
- **Terminal Charcoal:** the terminal background, paired with pale terminal ink and muted terminal guidance.

State colors are semantic: green for confirmed running/completed states, amber for uncertainty, and rust for destructive controls and field errors. General activity badges retain a neutral treatment; do not assume every completed activity is green.

**The Evidence Rule.** Pair state color with words; a machine state never implies service readiness.

## Typography

**Display and Body Font:** DM Sans Variable, with sans-serif fallback. **Code Font:** JetBrains Mono Variable, with monospace fallback. Both variable families are bundled by the application.

The interface face is direct and approachable; the mono face makes literal machine information easy to identify. Headings use moderate weight and tight tracking rather than decorative scale.

### Hierarchy

- **Display:** the responsive page heading, using the frontmatter display role.
- **Headline:** workspace headings; the welcome and setup variants are larger, with the welcome title constrained to a short measure.
- **Title:** working-area headings.
- **Body:** explanatory paragraphs, limited to a maximum measure of 70 characters; the desktop page introduction is slightly larger.
- **Label:** form labels and dense utility descriptions.
- **Command and Output:** separate monospace roles for entry and retained results. Compact metadata is subordinate to headings and control labels.

**The Code Rule.** Reserve the monospace family for commands, code, identities, and output.

## Layout

The centered shell has a maximum width of 1440px and desktop horizontal padding of 48px. The masthead is 88px tall. The page heading uses generous vertical spacing before a single bounded workspace. Within the workspace, a flexible main column sits beside a 310px tools column; full-width terminal and diagnostics areas follow. Rules establish sections without turning every item into a card.

At 1050px and below, shell padding becomes 28px, the tools column becomes 270px, and command options use two columns with the working directory spanning both. At 740px and below, shell padding becomes 16px, the masthead becomes 72px, the workspace stacks in reading order, and the tools border moves to the top. Supporting areas use roughly 20–24px internal padding. Command buttons share their row; lifecycle controls and section headings wrap.

The spacing scale records observed values rather than imposing a synthetic grid. Commands and output wrap long content; output panes scroll beyond 280px, submitted command blocks beyond 100px. Commands, Files, Terminal, and Activity anchor links provide direct navigation. The first two activity entries remain visible, with earlier requests disclosed on demand. The terminal is 320px tall on desktop and 280px on narrow screens, with a minimum of 180px and vertical resizing.

## Elevation & Depth

The system has no drop shadows. Ivory surfaces, darker control borders, pale dividers, and the terminal's dark field create hierarchy. Focus is an outline, not simulated elevation. Feedback reveals over 180ms using a small clipping transition; control fills change over 140ms. Reduced-motion preferences disable transitions and animations.

**The Flat Surface Rule.** Separate working areas with fine rules and tonal changes, without drop shadows.

## Shapes

Use the frontmatter surface radius for major bounded work areas, control radius for buttons and terminal, field radius for inputs and output panes, and badge radius for compact states. Borders are fine and continuous. Rows inside the workspace are divided, not individually rounded. Icons are simple inline stroke SVGs with no decorative icon backgrounds.

## Components

### Buttons

Compact, legible controls with semibold labels. Standard buttons use the ivory surface and a muted border; the primary variant uses olive and olive ink. Filled rust is reserved for the explicit destructive confirmation, while the initial Delete action is rust text on transparent fill. The compact size reduces padding to 8px 14px. Inline arrows remain subordinate to words.

Primary and secondary hover states change fill without movement. All interactive controls retain a 3px focus outline with a 4px offset. Disabled buttons use reduced opacity and a not-allowed cursor. The filled destructive confirmation keeps its rust fill on hover; its later variant rule wins over the generic button hover.

### Inputs / Fields

Ivory fields use a muted stroke, modest corners, full available width, and visible labels. The command field uses a faint green tint, monospace, generous padding, and vertical resize. Focus keeps the common outline and olive caret. Field errors use rust text plus an explicit message. The working directory spans the options grid at intermediate and narrow sizes.

### State Badges

Small rectangular labels with gently rounded corners and compact horizontal padding. State words remain visible in every palette treatment. These are informational badges, not filter chips or actions.

### Cards / Containers

Major workspace, welcome, and setup surfaces share an ivory fill, pale rule, and restrained surface radius. The workspace groups multiple sections within one enclosure. Supporting tools use a quiet tint; retained output uses a separate shaded field. No shadows are applied.

### Links and Disclosures

The brand is a simple text-and-outline-SVG home link; the interface has no sidebar navigation or tab system. Documentation links use underlines; the mapped service uses a full-width ruled row and external-arrow SVG. Disclosure summaries progressively reveal request identity, earlier activity, samples, and diagnostics. Preserve keyboard focus on links and summaries.

### Activity and Feedback

Keep the submitted command or file path next to its retained outcome, with request identity available beneath it. Results are literal output in a tinted monospace block. A persistent, polite, atomic status region announces changed machine and execution outcomes, including distinct request identity. Visible notices and explicit errors supplement that channel. The service heading is neutral: “Mapped service.”

### Terminal

A real xterm surface uses the dark terminal palette and monospace family. The shell can resize vertically; Escape moves focus to the section's control button. Opening, reconnecting, disconnecting, and observed exit remain different states. Browser loss has a 30-second controller-local reconnect window; explicit disconnect requires confirmation. Terminal bytes are not presented as saved activity.

## Do's and Don'ts

### Do:

- Do use olive to identify the primary action in a working area.
- Do pair every status treatment with a readable label.
- Do preserve visible focus, polite status announcements, and the terminal Escape path.
- Do keep code and request identities selectable and allow long values to wrap.
- Do stack working areas in their existing reading order on narrow screens.

### Don't:

- Don't use decorative cards, fabricated dashboards, or illustrative material costumes.
- Don't imply a service is ready solely because the machine is running.
- Don't remove request identity or uncertainty to make a screen look cleaner.
- Don't add decorative animation to operational feedback.
