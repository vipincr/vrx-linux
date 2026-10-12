/// The vrx metrics, ported from evrx-rt's `ui_metrics.h` — the numbers
/// are the design; the mm values are the truth and the dp values are
/// the mm at Flutter's logical density (1mm = 160/25.4 ≈ 6.299dp), so
/// a touch minimum is 9mm on every panel the way it is on evrx-rt's.
///
/// evrx-rt computes px from mm via the panel's PPI
/// (`UI_MM(mm) = (mm·PPI·100+1270)/2540`); Flutter bakes density into
/// dp, so the mm→dp conversion is fixed and the physical size holds.
library;

/// Millimetres to logical dp.
const double mmToDp = 160.0 / 25.4;

/// The spacing scale: 1 / 2 / 3 / 4 / 6mm. Pick by role, never by
/// number: XS glyph gaps, SM inside a control, MD a control's default
/// margin, LG between groups, XL screen margins.
abstract final class Spacing {
  /// 1mm.
  static const double xs = mmToDp;

  /// 2mm.
  static const double sm = 2 * mmToDp;

  /// 3mm.
  static const double md = 3 * mmToDp;

  /// 4mm.
  static const double lg = 4 * mmToDp;

  /// 6mm.
  static const double xl = 6 * mmToDp;

  /// The minimum touch target: 9mm.
  static const double touch = 9 * mmToDp;

  /// The screen edge inset: 2mm.
  static const double inset = 2 * mmToDp;

  /// The gutter between list rows: 2mm.
  static const double gutter = 2 * mmToDp;
}

/// Lines and strokes.
abstract final class Strokes {
  /// A hairline: 2 physical px at evrx-rt's reference; the thinnest
  /// ink a panel holds.
  static const double hairline = 2;

  /// A border: 3px, 1.5× a hairline.
  static const double border = 3;
}

/// Corner radii: 1mm and 2mm.
abstract final class Radii {
  static const double sm = mmToDp;
  static const double md = 2 * mmToDp;
}

/// Gestures (ported thresholds).
abstract final class Gestures {
  /// A swipe needs 2.5mm of travel…
  static const double swipeMin = 2.5 * mmToDp;

  /// …and at least 60px/s of speed, dominant axis only.
  static const double swipeMinPxPerS = 60;

  /// Touch slop before a drag claims a contact: 2mm.
  static const double touchSlop = 2 * mmToDp;

  /// Paged scrolling keeps one touch-min of the previous screen as
  /// the anchor.
  static const double pageOverlap = 9 * mmToDp;
}

/// The status strip (7 slots), the icon-button square (5mm), the
/// strip's control (4mm) and height (control + 2·XS).
abstract final class Chrome {
  static const double iconButton = 5 * mmToDp;
  static const double statusButton = 4 * mmToDp;
  static const double statusHeight = 4 * mmToDp + 2 * mmToDp;
  static const int statusSlots = 7;
}
