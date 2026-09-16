# SoundcoreBridge — brand guidelines

## Mark

The headband **is** the bridge: an arc spanning two pillars, with the EQ curve
as the signal passing under it. Generated from source in `tools/make-icon.swift`
so it stays reviewable.

- Clear space: at least 12% of the icon's width on every side
- Minimum size: 32 px (below that the EQ curve stops reading — use the arc alone)
- Never restyle: no gradients on the glyph, no outlines, no drop shadows

## Colour

| Token | Hex | Use |
|---|---|---|
| Signal | `#4A9EFF` | primary accent, links, active controls |
| Signal deep | `#2468D6` | pressed and hover states |
| Ink | `#0B0F16` | page background |
| Panel | `#141A25` | cards, code blocks |
| Line | `#232C3B` | borders, rules |
| Text | `#E8EDF5` | body copy |
| Muted | `#8D9BB1` | secondary copy, labels |

The app additionally tints itself by listening mode — these are functional, not
decorative, and must stay distinguishable:

| Mode | Hex |
|---|---|
| Noise Cancelling | `#4A9EFF` |
| Ambient | `#26D0A6` |
| Normal | `#FFA347` |

Body text on Ink clears 4.5:1. Muted on Ink clears 4.5:1 at 15px and above.

## Typography

System stack, so the site matches the platform the app runs on.

| Role | Size | Weight |
|---|---|---|
| Display | clamp(34px, 6vw, 54px) | 700, tracking -0.025em |
| Section label | 13px | 600, uppercase, tracking 0.1em |
| Body | 16–17px | 400, line-height 1.65 |
| Code | 13.5px | ui-monospace |

## Voice

Precise and unembellished. State what was verified and what was not.

- **Say:** "Verified against a Space 2 (D1402)." · "Other models stay read-only until their offsets are confirmed."
- **Don't say:** "Blazing fast." · "Seamlessly control your audio experience." · "Supports all Soundcore devices."

Claims about hardware are claims about evidence. If it wasn't confirmed against
a real device, the copy says so.
