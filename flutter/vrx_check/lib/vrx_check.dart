/// Checks a vrx applet's layout on the displays vrx boards drive, by
/// computation: Flutter lays the screen out headless at a display's
/// pixels and pixel ratio, in the image's fonts, and the rules below run
/// over the rects of every text run and tap target. Nothing is painted
/// or looked at. `cargo xtask gate` runs every applet's layout test.
///
/// Screenshots (shots.dart) are the same mount, written to PNGs, for a
/// person who wants to see a screen.
library;

export 'src/displays.dart';
export 'src/fonts.dart';
export 'src/layout.dart';
export 'shots.dart';
