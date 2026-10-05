---
layout: doc
title: Sloppy Visual Design
---

# Sloppy Visual Design

This is the canonical visual design reference for Sloppy, approved by the owner on **2026-10-05**. The references are the owner-approved HTML presentation, stored separately from the repository, and the two owner-supplied wordmark images below. Its design values are preserved in this document.

Use this direction for product UI, websites, documentation visuals, presentations, and brand materials: warm paper, deep forest backgrounds, compact bold typography, generous space, and restrained color. Product interfaces retain functional controls and platform conventions.

## Approved wordmark

The wordmark is **`sloppy.`**, entirely lowercase, with a terminal period. Its dense, bold sans-serif lettering is part of the identity. Preserve the letter shapes, spacing, baseline, and period; the font is as important as the color.

### Dark version

![Approved Sloppy wordmark: paper lettering with a mint period on forest dark](/design/sloppy-wordmark-dark-reference.png)

- Background: forest dark `#20261e`.
- Lettering: warm paper `#f5f2e9`.
- Period: soft mint `#c8e2ae`.
- Keep the period on the same baseline, in the same font and weight as the lettering.

### Light version

![Approved Sloppy wordmark: ink lettering and period on warm paper](/design/sloppy-wordmark-light-reference.png)

- Background: warm paper `#f5f2e9`.
- Lettering and period: ink `#242521`.
- The monochrome period in this version is intentional.

These are the owner's supplied references, preserved without edits. Their principal RGB values match the presentation tokens. The different image dimensions are reference crops, not prescribed logo dimensions.

### Font and spacing

The presentation renders the logo as live text using this exact CSS:

```css
font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Arial, sans-serif;
font-size: 29px;
font-weight: 750;
letter-spacing: -1.2px;
```

This is a **system sans-serif wordmark**, not a separately bundled custom font. On Apple surfaces the stack requests the Apple system font, commonly SF Pro; other systems resolve the listed fallbacks. The CSS does not pin a font file or guarantee identical glyphs on every platform. Keep the approved images as the visual authority when checking the result.

Scale tracking proportionally with logo size: `-1.2 / 29`, approximately **`-0.04138em`**. Preserve weight 750 where the font supports it; static fallback fonts may select a nearby weight. Native implementations should match the reference visually rather than assume a named system weight is an exact numeric equivalent.

```html
<span class="sloppy-wordmark">sloppy<span class="sloppy-wordmark-dot">.</span></span>
```

```css
.sloppy-wordmark {
  display: inline-block;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Arial, sans-serif;
  font-size: 29px;
  font-weight: 750;
  letter-spacing: -0.04138em;
  white-space: nowrap;
  color: #242521;
}

.sloppy-wordmark-on-dark {
  color: #f5f2e9;
}

.sloppy-wordmark-on-dark .sloppy-wordmark-dot {
  color: #c8e2ae;
}
```

Use the base class on paper; add `sloppy-wordmark-on-dark` on forest. If exact cross-platform glyph reproduction is required, use artwork made from and checked against the approved reference rather than silently changing the font. The attached PNGs are documentation references with baked backgrounds, not transparent production assets.

### Logo rules

- Keep the spelling `sloppy.`; do not capitalize the wordmark or omit the period. Product names in prose may still use “Sloppy”.
- Use the approved light or dark configuration. The dark version's mint period is its only internal color accent.
- Give the logo clear space on every side. A practical minimum is half the rendered wordmark height; increase it on covers and standalone compositions.
- Scale uniformly. Do not stretch, outline, add shadows, or enclose the logo in a decorative badge.
- Do not substitute Fira Code, another monospace, a rounded font, or a decorative face.
- Check the period at small sizes. Render it as a glyph, not a separate geometric circle.

## Palette

These values were captured from the approved HTML presentation and are preserved here as the canonical palette.

| Role | Value | Use |
| --- | --- | --- |
| Warm paper | `#f5f2e9` | Main light background; text on forest |
| Forest dark | `#20261e` | Dark backgrounds and covers |
| Ink | `#242521` | Main text on paper or mint |
| Soft mint | `#c8e2ae` | Highlight backgrounds; dark wordmark period; emphasis on forest |
| Coral | `#d94e34` | Selective emphasis and occasional section backgrounds |
| Muted text on paper | `#6d7066` | Supporting text |
| Divider on paper | `#d5d7ca` | Thin separators and table rules |
| Muted text on forest | `#b5bfad` | Supporting text on dark surfaces |
| Divider on forest | `#52604a` | Thin separators on dark surfaces |
| Divider on mint | `#9bbc80` | Separators on mint backgrounds |

Paper and forest are the principal backgrounds. Mint provides a softer highlight; coral provides stronger emphasis. Use color to establish hierarchy rather than distribute every accent across every screen.

Coral is a large-text or graphical accent: coral on paper and paper on coral should not be assumed to pass normal-text contrast requirements. Use ink for normal text on light surfaces, check actual foreground/background pairs, and provide visible keyboard focus. Status meaning also needs text or an icon. The presentation does not define a complete accessible status-color system.

## Typography

Use the same system sans-serif stack for interface and editorial text. Reserve monospace for code, command output, identifiers, and technical data that benefit from aligned glyphs. Do not make the whole interface monospaced.

Headings are large and compact; body text uses a regular weight and comfortable line height. Negative tracking belongs to large headings and the wordmark, not body text.

The presentation's desktop reference canvas is **1600 × 900**. These are its verified CSS values, not fixed sizes for every app or viewport:

| Element | Size | Weight | Tracking | Line height |
| --- | --- | --- | --- | --- |
| Cover title | `112px` | `650` | `-6px` | `1.01` |
| Slide title | `62px` | `620` | `-2.9px` | `1.07` |
| Section heading | `32px` | `650` | `-0.7px` | `1.15` |
| Lead paragraph | `29px` | Regular | Normal | `1.38` |
| Body paragraph | `26px` | Regular | Normal | `1.42` |
| Supporting copy | `21px` | Regular | Normal | `1.4` |
| Footnote | `18px` | Regular | Normal | `1.45` |
| Wordmark | `29px` | `750` | `-1.2px` | Inherits local text context |

Scale editorial typography for the target canvas. In product UI, choose sizes suited to controls, content density, platform conventions, and accessibility; preserve the hierarchy rather than copying presentation pixels. On Apple platforms, keep text scaling and native interaction behavior.

## Composition

- Establish one main focal point: a heading, statement, screenshot, or comparison. Give it room.
- Use a flat canvas with clear alignment. Prefer open columns, text rows, and thin rules to decorative card grids.
- Keep generous margins and a consistent rhythm between heading, explanation, and evidence.
- Keep text groups purposeful. Avoid redundant kickers, labels, badges, and footer fragments.
- Use tables for real comparisons and numbered sequences for real steps; keep their styling quiet.
- Use genuine product screenshots when they help explain a feature. Preserve aspect ratio and identify examples accurately.
- Paper, forest, and mint backgrounds can distinguish sections. Use coral backgrounds sparingly.
- Avoid decorative gradients, glows, hard offset shadows, neon outlines, and busy backgrounds.

On its reference canvas the presentation uses `56px` top padding, `90px` horizontal padding, `80px` bottom padding, and a `36px` gap after the top line. These establish the rhythm for presentation materials; app screens use their own consistent responsive spacing.

## Product interfaces

Apply palette, typography, and spacing while respecting the information and interaction model.

- Keep navigation, inputs, actions, and status readable. Use containers when functional grouping helps users; avoid adding cards merely to decorate a screen.
- Separate rows with thin lines or restrained surface changes.
- Keep native controls, focus behavior, selection, scrolling, accessibility identifiers, and platform semantics.
- Preserve repository interaction rules, including the Dashboard's custom `.actor-team-search` dropdown pattern.
- Do not impose the presentation's fixed canvas or exact pixel sizes on product screens.
- Keep the wordmark consistent even when surrounding UI uses native text styles.

## Responsive layouts and verification

A presentation may use a scaled desktop canvas; mobile reading layouts must reflow. Stack columns and comparison rows when needed. Long labels must not force the document wider than the viewport. Do not fix overflow by shrinking text until it becomes unreadable.

Check relevant light and dark surfaces, logo spelling and color, typography, alignment, contrast, and actual viewport behavior. For presentations, also inspect all slides, speaker overlays, navigation, and print output. For app UI, inspect the affected running screen using the project's normal platform workflow.

## Existing implementation and migration

The current Dashboard stylesheet and docs theme still contain the earlier black/acid-lime palette, hard borders, and Fira Code-first typography. Those values describe the existing implementation; they are **not the approved target identity for new work**.

This document supersedes the previous visual guidance on this page. Apply it within each requested task, preserving working behavior and unrelated changes. Documentation changes alone do not migrate the Dashboard, native clients, website, or docs theme.

## Reference files

- Original HTML presentation: stored separately from the repository; its design specification is preserved in this document.
- [Dark wordmark reference](/design/sloppy-wordmark-dark-reference.png)
- [Light wordmark reference](/design/sloppy-wordmark-light-reference.png)
- Repository instructions: `AGENTS.md`, section “Visual design and brand”

The specification and reference images live in this repository so future work does not depend on temporary clipboard paths or chat history.
