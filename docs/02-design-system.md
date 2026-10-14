# 02 · The design system

Every number here comes from one file, `flutter/vrx_kit/standard/vrx-ui-standard.toml`,
vendored from evrx-rt and pinned by hash (`flutter/vrx_kit/standard/PIN`).
`cargo xtask ui-standard` generates `lib/src/ui_standard.g.dart` from it,
and the gate fails if either the pin or the generated file is stale (G018).
An applet never writes a size, a colour or a curve; it names a role.

## Units

The standard is in millimetres and points, so a control is the same size
under a finger on a 43 mm panel and a 24" monitor. The kit converts at
Flutter's logical density: `mmToDp = 160 / 25.4` (about 6.3 dp per mm) and
`ptToDp = 160 / 72`. Lines are the exception: `Strokes.hairline` (2) and
`Strokes.border` (3) are device pixels, so a rule lands on whole pixels on
a panel with four greys.

## Spacing and size

| Role | mm | Use |
|---|---|---|
| `Spacing.xs` | 1 | between a glyph and its label |
| `Spacing.sm` | 2 | inside a control; the gutter between rows |
| `Spacing.md` | 3 | a control's margin |
| `Spacing.lg` | 4 | between groups |
| `Spacing.xl` | 6 | screen margins |
| `Spacing.inset` | 2 | glass edge to the client area |
| `Spacing.touch` | 9 | the smallest thing a finger is asked to hit |
| `Chrome.iconButton` | 5 | a glyph that is itself a control (its hit area still grows to 9) |
| `Chrome.statusButton` | 4 | a glyph in the status strip |
| `Radii.sm`, `Radii.md` | 1, 2 | corners |

Pick by role, never by number: three margins on one screen look broken.

## Type

Pick a role, never a size (`TypeRole.of(context, VrxTypeRole.body)` or the named
helpers on `TypeRole`):

| Role | pt | Use |
|---|---|---|
| display | 14.5 | the one big thing on a screen |
| title | 12.5 | a screen's header |
| subtitle | 11.2 | a section |
| body | 9.9 | reading text (3.5 mm on every panel) |
| subtext | 8.5 | a row's detail, a value |
| micro | 6.6 | the strip's date |
| clock | 42.1 | Clock's face |
| code | 8.5 | monospace (Terminal, Scripts) |

`emphasis`, `list`, `value` and `caption` are derived from these. Text is
fitted to the widest string its slot will ever hold (`VrxFitText`), and a
cut reveals the whole text (`VrxRevealText`); a setting's label is never
cut.

## Colour

Colour is by role: 32 slots, paired where one sits on another (`primary`
with `on_primary`, `error` with `on_error`), read with
`VrxColors.of(context)`. Twenty schemes come from four seed hues (blue 255,
green 150, amber 65, magenta 330, in OKLCh) and five harmony rules
(analogous, complementary, split, triadic, tetradic), each in light and
dark, with contrast floors held by tests. The scheme is a system setting
(Settings > Display > Colour scheme) applied at the next boot through
`vrx-theme` (plan 0009).

The display class (`lcd_colour`, `lcd_grey`, `epaper_grey`, `epaper_mono`)
is the board's, set by `VRX_DISPLAY_CLASS` in its machine conf; the kit maps
the slots to greys where the panel has no colour. An applet never asks
which class it is on (the scan refuses it).

A signal is never colour alone: an error carries a glyph and a sentence,
Wi-Fi off has its own glyph, a chosen segment fills.

## Motion

Six springs (`MotionTokens`, Material 3's values in Flutter's spring
physics): `spatialFast`, `spatial`, `spatialSlow` may overshoot and move
position or size; `effectsFast`, `effects`, `effectsSlow` are critically
damped and change colour or opacity. A colour never rides a spatial spring.
`Motion.push` slides a screen in from the right; a modal fades over a
dimmed field. A press is instant: it sinks to 0.97 on `spatialFast` and acts
on release.

## Components

| Component | Use |
|---|---|
| `VrxHeader` | a screen's title, with Back where there is one |
| `VrxList`, `VrxSection`, `VrxRow` | lists and settings; a row with no action is a status line |
| `VrxSegmented` | one choice of a few; the chosen cell fills |
| `VrxChip` | a filled action |
| `VrxIconButton` | a glyph control, grown to the touch minimum |
| `VrxBanner` | a persistent notice; clears on the next screen; there is no toast |
| `VrxPress` | press feedback for anything tappable the kit has no component for |
| `vrxConfirm`, `vrxAsk` | dialogs: Cancel left, the act named, the destructive act last |
| `VrxSlider` | a value on a track; arrow keys step it |
| `VrxWheel`, `VrxTimePicker`, `VrxDatePicker` | scrolled choices with a key form |
| `VrxTextEntry`, `VrxKeyboard` | text, with the on-screen keyboard |
| `VrxZonePicker`, `VrxSchemePicker` | the system pickers |
| `VrxQr` | a QR code at least 18 mm wide |
| `VrxStatusStrip`, `VrxQuickDrawer` | the shell's strip and drawer |

The strip has fixed slots, so the clock does not move when Back appears.
A modal belongs to the client area and the strip stays visible above it.

## Layout

Layout is computed. `flutter/vrx_check` lays every screen out on every
display in `flutter/vrx_check/lib/displays.json` (the 2.8" panel, 7" DSI
and HDMI panels, a 1080p monitor, a monitor with no EDID size) and fails
on an overflow, text cut or wrapped inside a word, text clipped by its
box, text over text, a control over a control, a control under 9 mm on a
touch display, a dialog whose message scrolls when it could fit, and
anything off the glass. `01-applet-guide.md` has how an applet keeps its
layout test.
