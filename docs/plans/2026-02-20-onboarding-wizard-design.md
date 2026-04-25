# Onboarding Wizard Redesign

**Date**: 2026-02-20
**Status**: Approved

## Overview

Redesign the OnboardingWizardView from a basic grouped form into a polished, Raycast-inspired dark wizard with vibrant accents, two-column layouts, and smooth horizontal slide transitions.

## Window & Chrome

- 700x500, non-resizable, centered
- Dark background (#1C1C1E), hidden title bar
- Draggable from background area

## Navigation (Bottom Bar)

- Left: "Skip" plain text button
- Center: 4 step-indicator dots (active = accent gradient fill, inactive = dimmed)
- Right: "Back" (bordered, hidden on step 1) + primary action (filled, accent gradient)

## Steps

### Step 1: Welcome (Full-Width Hero, Centered)

- SF Symbol `wand.and.stars.inverse` 56pt with circular gradient glow
- Title: "Welcome to Jack" 28pt bold white
- Subtitle: one-line description, 15pt secondary
- Checklist: 3 items with dimmed circle-check icons
- Primary: "Get Started"

### Step 2: Permissions (Two-Column)

- Left (~35%): `lock.shield.fill` 44pt green-teal gradient, title, subtitle
- Right (~65%): 3 permission cards (dark rounded rects #2C2C2E) each with icon, title, status badge, description, "Open Settings" link
- "Request All Permissions" accent button + "Re-check" bordered
- Orange warning if incomplete
- Primary: "Continue"

### Step 3: Shortcut Setup (Two-Column)

- Left (~35%): `keyboard.fill` 44pt blue-indigo gradient, title, subtitle
- Right (~65%):
  - Invocation key card: current key display, "Change Key" button, pulsing glow when capturing
  - Shortcut mode: 3 selectable tile cards (Toggle/Hold/Double Tap) with accent border on selection
  - Voice note key: collapsed optional row
- Primary: "Continue"

### Step 4: Finish (Full-Width Hero, Centered)

- `checkmark.seal.fill` 56pt green gradient glow
- Title: "You're All Set" 28pt bold
- Summary card (~400px wide): key, mode, permissions status
- Primary: "Start Dictating"

## Transitions

- Horizontal slide: forward slides left, back slides right
- Spring animation
- Step dots animate position smoothly

## Color Palette

| Token       | Value    |
|-------------|----------|
| Background  | #1C1C1E  |
| Card        | #2C2C2E  |
| Text        | White    |
| Secondary   | #8E8E93  |
| Accent from | #5E5CE6  |
| Accent to   | #007AFF  |
| Success     | #30D158  |
| Warning     | #FF9F0A  |

## Scope

- Replace `OnboardingWizardView.swift` entirely
- Minimal changes to `DictationController` (same API surface)
- No changes to `ContentView` in this phase
