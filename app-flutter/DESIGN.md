---
name: Rift System Protocol
colors:
  surface: '#fdf8f6'
  surface-dim: '#ddd9d7'
  surface-bright: '#fdf8f6'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f7f3f0'
  surface-container: '#f1edeb'
  surface-container-high: '#ece7e5'
  surface-container-highest: '#e6e2df'
  on-surface: '#1c1b1a'
  on-surface-variant: '#434653'
  inverse-surface: '#31302f'
  inverse-on-surface: '#f4f0ee'
  outline: '#737685'
  outline-variant: '#c3c6d6'
  surface-tint: '#2156ca'
  primary: '#00328a'
  on-primary: '#ffffff'
  primary-container: '#0047bb'
  on-primary-container: '#afc1ff'
  inverse-primary: '#b3c5ff'
  secondary: '#006e06'
  on-secondary: '#ffffff'
  secondary-container: '#91f77e'
  on-secondary-container: '#007306'
  tertiary: '#701a00'
  on-tertiary: '#ffffff'
  tertiary-container: '#982700'
  on-tertiary-container: '#ffb09a'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#dbe1ff'
  primary-fixed-dim: '#b3c5ff'
  on-primary-fixed: '#00174a'
  on-primary-fixed-variant: '#003ea6'
  secondary-fixed: '#94fa81'
  secondary-fixed-dim: '#79dd68'
  on-secondary-fixed: '#002200'
  on-secondary-fixed-variant: '#005303'
  tertiary-fixed: '#ffdbd1'
  tertiary-fixed-dim: '#ffb5a0'
  on-tertiary-fixed: '#3b0900'
  on-tertiary-fixed-variant: '#872100'
  background: '#fdf8f6'
  on-background: '#1c1b1a'
  surface-variant: '#e6e2df'
typography:
  headline-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-md:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  headline-sm:
    fontFamily: Inter
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
  body-lg:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  label-mono:
    fontFamily: JetBrains Mono
    fontSize: 13px
    fontWeight: '500'
    lineHeight: 16px
    letterSpacing: 0.05em
  label-mono-sm:
    fontFamily: JetBrains Mono
    fontSize: 11px
    fontWeight: '400'
    lineHeight: 14px
  headline-lg-mobile:
    fontFamily: Inter
    fontSize: 26px
    fontWeight: '700'
    lineHeight: 32px
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  base: 4px
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  gutter: 16px
  margin-mobile: 16px
  margin-desktop: 48px
---

# Rift System Protocol - Design System

## Brand & Style
The design system is engineered for **Rift**, a high-utility security tool for device synchronization. The brand personality is rooted in **Cyber-Reliability**: it is clinical, authoritative, and transparent. The interface must evoke a sense of "hardened" security—users should feel that their data is protected not through obfuscation, but through robust, visible encryption and clear state management.

The design style follows a **Modern Corporate** aesthetic with **Functional Brutalist** undertones. It prioritizes information density and utilitarian clarity over decorative elements. It utilizes structured grids, high-contrast states, and specific typographic treatments to distinguish between human-readable actions and machine-generated security data.

## Colors
The palette is centered on **Trust Blue**, a high-saturation, deep navy that signals stability and enterprise-grade encryption. 

- **Primary (Trust Blue):** Used for primary actions, active connection states, and brand-identifiable elements.
- **Success (Trusted Green):** Reserved exclusively for verified pairings and successful transfers.
- **Warning (Pending Amber):** Used for unverified devices and discovery phases.
- **Danger (Revoked Red):** Used for blocked hardware, expired tokens, and critical security mismatches.
- **Neutral:** A range of cool grays. In dark mode, use deep charcoal (`#121212`) to reduce eye strain while maintaining high contrast for technical data.

## Typography
The system employs a dual-typeface strategy to separate UI navigation from security data.

- **Inter (Sans-Serif):** Used for all functional UI elements, headers, and instructional text. Its neutral, systematic nature ensures high legibility in dense layouts.
- **JetBrains Mono (Monospace):** Reserved for technical identifiers—Device IDs, Fingerprints, Hashes, and Word-lists. This visual distinction alerts the user that they are viewing "System Data" which requires verification.

**Hierarchy Rules:**
- Use `headline-md` for device names in cards.
- Use `label-mono` for all hash outputs and ID strings.
- Bold weights should be used sparingly for status indicators (e.g., **CONNECTED**).

## Layout & Spacing
The layout follows a **Fluid Grid** model with a strict 4px baseline rhythm. 

- **Desktop/Tablet:** 12-column grid with 24px gutters. Use sidebar navigation for device lists and a primary central area for active clipboard or pairing logs.
- **Mobile:** Single column with 16px margins. Utilize Material 3 bottom sheets for "Add Device" or "Security Info" to keep the main view focused on the active connection list.
- **Information Density:** Vertical spacing is tight (`8px` or `12px` between list items) to allow for the monitoring of multiple devices simultaneously without excessive scrolling.

## Elevation & Depth
This design system uses **Tonal Layers** and **Low-Contrast Outlines** rather than heavy shadows to maintain a professional, utility-driven feel.

- **Level 0 (Background):** Base surface (`#F5F7F8` or `#121212`).
- **Level 1 (Cards/Containers):** Slightly elevated using a 1px solid border (`#D1D5DB` or `#2E2E2E`) and a secondary surface color.
- **Level 2 (Active States/Popovers):** Subtle, tight shadow (0px 2px 4px rgba(0,0,0,0.05)) and a high-contrast border to indicate focus.
- **Interaction:** On hover or active state, cards should not "lift" (no shadow change), but instead change border color to `Primary Trust Blue`.

## Shapes
The shape language is **Soft (0.25rem)**. This provides a professional, modern look without the "playfulness" of highly rounded corners.

- **Buttons & Inputs:** `rounded-sm` (4px).
- **Cards & Bottom Sheets:** `rounded-lg` (8px).
- **Status Dots:** Perfect circles (100% radius) for immediate recognition.
- **Fingerprint Blocks:** Containers should use 4px rounding to frame the monospaced text as a discrete unit of data.

## Components

### Device Cards
The primary unit of the UI.
- **Structure:** Platform icon (Top Left), Device Name (Headline-md), Status Dot (Success/Warning/Danger), and a "Trust Badge" icon.
- **Styling:** 1px border, minimal internal padding (12px). Display the last-seen timestamp in `label-mono-sm`.

### Fingerprint Blocks
- **Word-lists:** Large font-size Inter, bold, for easy verbal verification during pairing.
- **Hex/Hash:** Below word-lists, using `label-mono-sm` in a muted gray container.

### Banners (System Alerts)
- **Design:** Full-width at the top of the viewport or container.
- **Logic:** Use solid background colors for Error/Danger, and tinted borders with white/dark backgrounds for Info/Warning to prevent visual fatigue.
- **Iconography:** Always include a state-specific icon (e.g., a shield-x for blocked) to ensure accessibility for color-blind users.

### Filter Chips
- **Usage:** For logs and history filtering.
- **Style:** Outlined buttons with 16px height, using `label-mono` for the text.

### Buttons
- **Primary:** Solid Trust Blue with white text.
- **Secondary:** Outlined with 1px Trust Blue border.
- **Destructive:** Solid Blocked Red for "Revoke Access" or "Clear History."
