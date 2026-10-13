/// The vrx metrics, from the vrx UI standard (standard/vrx-ui-standard.toml,
/// generated into ui_standard.g.dart): the mm values are the truth and the
/// dp values are the mm at Flutter's logical density (1mm = 160/25.4 ≈
/// 6.299dp), so a touch minimum is 9mm on every panel, as on evrx-rt's.
///
/// evrx-rt computes px from mm via the panel's PPI
/// (`UI_MM(mm) = (mm·PPI·100+1270)/2540`); Flutter bakes density into
/// dp, so the mm→dp conversion is fixed and the physical size holds.
library;

import 'ui_standard.g.dart';

/// Millimetres to logical dp.
const double mmToDp = 160.0 / 25.4;

/// Typographic points to logical dp: a point is 1/72 inch, a dp 1/160
/// inch. evrx-rt's type scale is in points (rendered at the panel's
/// PPI), so 9.9pt body text is 3.5mm on every panel, here as there.
const double ptToDp = 160.0 / 72.0;

/// The spacing scale (the standard's [spacing_mm]: 1 / 2 / 3 / 4 / 6mm).
/// Pick by role, never by number: XS glyph gaps, SM inside a control, MD
/// a control's default margin, LG between groups, XL screen margins.
abstract final class Spacing {
  static const double xs = vrxSpacingMmXs * mmToDp;
  static const double sm = vrxSpacingMmSm * mmToDp;
  static const double md = vrxSpacingMmMd * mmToDp;
  static const double lg = vrxSpacingMmLg * mmToDp;
  static const double xl = vrxSpacingMmXl * mmToDp;

  /// The minimum touch target ([size_mm] touch_min).
  static const double touch = vrxSizeMmTouchMin * mmToDp;

  /// Between the glass edge and the client area ([spacing_mm] edge_inset).
  static const double inset = vrxSpacingMmEdgeInset * mmToDp;

  /// The gutter between list rows: the SM step.
  static const double gutter = sm;
}

/// Lines and strokes, in device pixels and never scaled ([device_px]): a
/// line on whole pixels stays a line on a panel with four greys.
abstract final class Strokes {
  /// A rule, a thin frame, the seam between two controls.
  static const double hairline = vrxDevicePxHairline;

  /// A control's frame, the focus frame.
  static const double border = vrxDevicePxBorder;
}

/// Corner radii ([radius_mm]).
abstract final class Radii {
  static const double sm = vrxRadiusMmSm * mmToDp;
  static const double md = vrxRadiusMmMd * mmToDp;
}

/// Gestures ([gesture]).
abstract final class Gestures {
  /// A swipe needs this much travel…
  static const double swipeMin = vrxGestureSwipeMinMm * mmToDp;

  /// …and at least this speed, dominant axis only.
  static const double swipeMinPxPerS = vrxGestureSwipeMinPxPerS;

  /// Travel past which a contact is no longer a tap.
  static const double touchSlop = vrxGestureTouchSlopMm * mmToDp;
}

/// The icon-button square, the strip's glyph, and the strip's height (its
/// glyph and an XS above and below).
abstract final class Chrome {
  static const double iconButton = vrxSizeMmIconButton * mmToDp;
  static const double statusButton = vrxSizeMmStatusButton * mmToDp;
  static const double statusHeight = statusButton + 2 * Spacing.xs;
}
