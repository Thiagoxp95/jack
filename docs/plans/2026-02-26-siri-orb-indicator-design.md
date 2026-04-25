# Siri-Inspired Orb Indicator Design

## Summary

Replace the notch-hugging recording indicator with a Siri-inspired glowing orb positioned at the bottom center of the screen. The orb uses the active space's color as its primary hue and displays the space icon at center.

## Visual Design

### Layers (bottom to top)

1. **Glow layer** — Large soft radial gradient using space color, fading to transparent. Voice-reactive: radius and opacity increase with voice amplitude.
2. **Orb background** — Circular dark glass-like base (`black @ 0.7`) with slight blur/transparency.
3. **Animated gradient overlay** — Rotating gradient ring using space color + lighter/darker variants that swirl continuously. Speed increases with voice amplitude.
4. **Space icon** — SF Symbol or emoji centered in the orb, white/tinted, voice-reactive brightness (same exponential smoothing as current).

### Sizing

- User-configurable via existing `floatingIndicatorSizePercent` (18-140%)
- Base diameter: 72pt at 100%. Scales linearly with the percentage.
- Glow extends ~40% beyond the orb diameter.

### Voice Reactivity

- **Idle**: Slow gradient rotation (~4s full revolution), soft glow at 30% opacity, icon at 0.5 alpha.
- **Speaking**: Faster rotation (proportional to amplitude), glow brightens to 80% and expands, icon brightens to full, subtle scale pulse (1.0 → 1.03).
- Same 7% gating threshold and exponential smoothing (tau=0.008s) as current.

## Panel & Positioning

- Bottom center of screen, 48pt above screen bottom edge.
- Panel size = orb diameter + glow padding (e.g., 72 + 60 = 132pt square at 100%).
- Same NSPanel config: borderless, non-activating, statusBar level, canJoinAllSpaces, fullScreenAuxiliary, ignoresMouseEvents.
- No notch detection needed.

## Public API (unchanged)

```swift
// These methods stay identical — DictationController needs zero changes
func show(message:isRecording:isTranscribing:isNoteMode:riveAssetPath:htmlIndicatorMarkup:useBuiltInWaveIndicator:)
func hide()
func updateWaveReactiveInputs(listening:transcribing:level:shouldPulse:)
func setSpaceAppearance(color:icon:)
func setPresentation(position:sizePercent:)
```

## What Changes

- `VoiceWaveView` → deleted (replaced by gradient animation on orb)
- `NotchIndicatorContentView` → replaced by `SiriOrbView`
- `FloatingBubbleController` positioning logic → simplified (no notch detection, just bottom-center)
- `FloatingBubbleController` sizing → based on `sizePercent` mapped to orb diameter

## What Stays

- All DictationController integration (zero changes)
- Voice level gating/smoothing math
- Space icon display logic (SF Symbol vs emoji, note mode swap)
- Pulse animation concept (adapted to orb scale)
- Animation timer pattern (30 FPS)
