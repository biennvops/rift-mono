---
name: Rift System
colors:
  surface: '#f8f9ff'
  surface-dim: '#cbdbf5'
  surface-bright: '#f8f9ff'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#eff4ff'
  surface-container: '#e5eeff'
  surface-container-high: '#dce9ff'
  surface-container-highest: '#d3e4fe'
  on-surface: '#0b1c30'
  on-surface-variant: '#434653'
  inverse-surface: '#213145'
  inverse-on-surface: '#eaf1ff'
  outline: '#737784'
  outline-variant: '#c3c6d5'
  surface-tint: '#2559bd'
  primary: '#00327d'
  on-primary: '#ffffff'
  primary-container: '#0047ab'
  on-primary-container: '#a5bdff'
  inverse-primary: '#b1c5ff'
  secondary: '#545f73'
  on-secondary: '#ffffff'
  secondary-container: '#d5e0f8'
  on-secondary-container: '#586377'
  tertiary: '#1a12af'
  on-tertiary: '#ffffff'
  tertiary-container: '#3636c5'
  on-tertiary-container: '#b7b8ff'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#dae2ff'
  primary-fixed-dim: '#b1c5ff'
  on-primary-fixed: '#001946'
  on-primary-fixed-variant: '#00419e'
  secondary-fixed: '#d8e3fb'
  secondary-fixed-dim: '#bcc7de'
  on-secondary-fixed: '#111c2d'
  on-secondary-fixed-variant: '#3c475a'
  tertiary-fixed: '#e1e0ff'
  tertiary-fixed-dim: '#c0c1ff'
  on-tertiary-fixed: '#07006c'
  on-tertiary-fixed-variant: '#2f2ebe'
  background: '#f8f9ff'
  on-background: '#0b1c30'
  surface-variant: '#d3e4fe'
typography:
  headline-xl:
    fontFamily: Inter
    fontSize: 40px
    fontWeight: '700'
    lineHeight: 48px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 40px
    letterSpacing: -0.01em
  headline-lg-mobile:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  headline-md:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  body-lg:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: '400'
    lineHeight: 28px
  body-md:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-sm:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  label-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.05em
  label-sm:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16px
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  unit: 4px
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  gutter: 16px
  margin-mobile: 16px
  margin-desktop: 32px
  sidebar-width: 280px
---

## Brand & Style
The design system is engineered for **Rift**, a secure cross-platform synchronization tool. The brand personality is anchored in **Professionalism, Reliability, and Precision**. It evokes a sense of impenetrable security through a structured, clinical aesthetic that remains highly accessible.

The visual style is **Corporate / Modern** with a focus on high-clarity information architecture. It leverages generous white space to reduce cognitive load during complex synchronization tasks. The aesthetic avoids unnecessary decoration, favoring functional clarity and a systematic approach to depth and hierarchy. The core metaphor is the "Secure Link"—represented by the intersection of solid forms and precise alignment.

## Colors
The palette is dominated by a deep, authoritative primary blue derived from the brand mark. This is supported by a sophisticated range of cool grays and deep slate tones to maintain a professional, secure atmosphere.

- **Primary Blue (#0047AB):** Used for primary actions, active navigation states, and critical branding elements.
- **Secondary Slate (#1E293B):** Used for text, sidebar backgrounds, and high-contrast UI components.
- **Neutral Scale:** A series of cool grays (from #F8FAFC to #64748B) defines the UI scaffolding and borders.
- **Semantic Status:** 
  - **Success:** Emerald green for completed syncs and verified security.
  - **Warning:** Amber for storage limits or sync conflicts.
  - **Error:** High-intensity red for security breaches or failed connections.
  - **Pending:** A vibrant violet-blue for active processes.

## Typography
This design system utilizes **Inter** exclusively for its utilitarian, highly legible characteristics. The type scale is optimized for readability at small sizes (essential for device names and file paths) and authoritative impact at larger sizes.

- **Headlines:** Use semi-bold and bold weights with slight negative letter-spacing to appear compact and modern.
- **Body:** Standardized on 16px for optimal desktop legibility, dropping to 14px for dense data tables or metadata.
- **Labels:** Use a slightly tighter tracking and semi-bold weight for secondary metadata and form headings.
- **Security Contexts:** Critical alerts use the `label-md` style to ensure immediate recognition.

## Layout & Spacing
The system employs a **Fluid Grid** with fixed-width constraints for optimal readability. The spacing rhythm is based on a 4px baseline, ensuring all components align to a predictable vertical and horizontal cadence.

- **Desktop (Expanded):** Utilizes a fixed left-side navigation (280px) with a fluid content area. Page content is capped at 1280px width for readability.
- **Mobile (Compact):** Shifts to a bottom navigation pattern with 16px safe-area margins.
- **Rhythm:** Use `lg` (24px) for spacing between major sections and `md` (16px) for internal card padding. This creates a clear "grouping" effect that aids in visual scanning.

## Elevation & Depth
Depth in this design system is expressed through **Tonal Layers** and **Low-Contrast Outlines**. We avoid aggressive shadows to maintain a clean, flat aesthetic that feels like a secure digital utility.

1. **Surface Base:** The primary background uses pure white (#FFFFFF).
2. **Surface Container:** Secondary areas like sidebars or secondary panels use a light gray tint (#F8FAFC).
3. **Ghost Borders:** Components like cards and input fields are defined by 1px solid borders in a soft neutral (#E2E8F0) rather than heavy shadows.
4. **Elevation Shadows:** Only used for floating elements like dropdowns or modals. These should be "Ambient Shadows": extra-diffused (20px-40px blur), low opacity (10%), with a slight tint of the primary blue to maintain color harmony.

## Shapes
The shape language is **Soft (0.25rem)**. This provides a professional edge while feeling modern. 

- **Standard Elements:** Buttons, inputs, and small chips use `rounded` (0.25rem).
- **Containers:** Large cards and modals use `rounded-lg` (0.5rem) to differentiate them as structural containers.
- **Strictness:** Do not use pill-shaped elements for primary buttons; keep the corner radius consistent to reinforce the "built-to-last" security narrative.

## Components
Consistent component styling reinforces the trust-based identity of the application.

- **Buttons:** 
  - *Primary:* Solid Primary Blue with white text. 
  - *Secondary:* Transparent with a 1px Primary Blue border.
  - *Destructive:* Solid Error Red with white text. These actions should always trigger a confirmation modal with high-contrast warning visuals.
- **Status Chips:** Small, subtle backgrounds (10% opacity of the status color) with high-contrast text. For example, a "Secure" chip uses a light green background with dark green text.
- **Input Fields:** 1px borders (#E2E8F0) that transition to Primary Blue on focus. Labels should always be visible above the field in `label-sm`.
- **Cards:** White background, 1px neutral border, and no shadow. Use a subtle 4px top-border accent in Primary Blue for "featured" or "active" device cards.
- **Navigation:**
  - *Sidebar (Desktop):* Dark Slate background with active states highlighted in Primary Blue.
  - *Bottom Bar (Mobile):* White background with a 1px top border and Primary Blue icons for active tabs.
- **Lists:** Clean rows with 1px bottom dividers. Use `body-md` for the title and `body-sm` in a neutral tint for metadata (e.g., "Last synced 2m ago").