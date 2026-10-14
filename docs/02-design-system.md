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

Every spring in vrx runs through one engine, `VrxMotion` in
`flutter/vrx_kit/lib/src/motion.dart`, over the UI standard's springs and
micro rows (plan 0017). A component names a micro row (`VrxMicro.press`,
`.drawerOpen`, `.screen`); the kit owns the numbers, and the scan (G050)
refuses an `AnimationController`, a `Curve`, an `Animated*` widget, a hand
duration or a `ScrollPhysics` anywhere else.

The vocabulary is two files. The vendored `standard/vrx-ui-standard.toml`
holds the springs (stiffness and damping ratio at mass 1) and the `[micro.*]`
rows; `standard/vrx-motion.toml` is vrx's own overlay and adds what vrx needs
beside it: which spring set each row reads, the rows `drawer_open`,
`drawer_close`, `applet` and `overscroll`, the class-to-tier map, the tolerance,
the ceilings and the touch sampling offset. The overlay may add and never
redefine a key of the vendored file (G018 pins both by hash). `cargo xtask
ui-standard` writes `ui_standard.g.dart` from them.

**Two spring sets.** Things that travel across the screen use the expressive
set and bounce: the drawer opening, a dialog growing in, a screen slide, an
applet's entrance, the end of a list. Controls that change in place use the
standard set, whose overshoot (0.15 %) cannot be seen: press, selection, the
slider handle, a key. A closing drawer stays standard, since an overshoot
would push the panel up through the strip. `effects` springs (colour,
opacity) are critically damped in both sets, and a colour never rides a
spatial spring.

**Tolerance is in pixels.** The engine stops a spring at half a device pixel
and 5 px/s (one 8-bit step for an opacity), not at Flutter's 1e-3, which kept
the standard `spatial` running 0.54 s over a 360 px drawer where it is done to
the eye at 0.26 s. Every simulation is built by `vrxSimulate(spring, from, to,
velocity, unit)`, and the unit says what a number is.

**Ceilings.** Each micro row a person waits on has an arrival and a settle
ceiling in the overlay, at its reference travel on the 480 px display:

| Motion | Arrives (ms) | Settles (ms) |
|---|---|---|
| press | 100 | 250 |
| drawer open (expressive) | 120 | 450 |
| drawer close | 120 | 300 |
| screen change | 170 | 400 |
| applet entrance | 170 | 300 |
| modal | 180 | 500 |
| banner in / out | 150 / 120 | 300 / 250 |
| list row | 110 | 250 |

`motion_ceiling_test.dart` integrates every row through the engine (G051); a
token swap or a stiffness edit that exceeds one fails.

**Tiers.** The build decides what moves: `still` (nothing; one paint of every
end state), `light` (position and opacity, scale only a press's, no stagger, a
slide without a fade) and `full` (the whole table). The tier comes from the
display class (`lcd_colour` full, `lcd_grey` light, e-paper still) or from
`VRX_UI_MOTION` in the machine conf, which `vrx-theme` validates and writes to
`/usr/lib/vrx/motion-tier`. Settings > Display > **Reduce motion** only takes
motion away on top of that (G053): every travel lands at once, a screen change
or an entrance is a quick fade, and press feedback is the same. There is no
frame-time watchdog: motion that changes with load reads as a bug.

**Where bounce has no room, it is not used.** A fade has nothing to overshoot,
and a full-screen slide that overshot would show the screen's edge.

## The drawer and screens

`VrxPull` is the drawer's mechanics: it follows the finger 1:1, flings onto a
spring with the finger's velocity, and rubber-bands past its end with Flutter's
own friction. A finger that lands on a moving drawer stops it. It owns the
position; the model keeps only the intent. The shell's region is the whole
screen from the first moved pixel until the close has landed.

`VrxSwitch` animates a screen change inside an applet: the new screen slides
in from the side by 10 mm while the old one leaves as a picture; deeper comes
from the right, shallower from the left, an equal depth cross-fades.
`AppletHost` installs it from the model's `screen` and `depth`.
`VrxEntrance` is an applet coming to the front.

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
| `VrxStatusStrip`, `VrxQuickDrawer`, `VrxPull` | the shell's strip, the drawer's panel, and the drawer's mechanics |

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
