/// The displays vrx boards drive, as the runtime sees them: pixels, and
/// the pixel ratio flutter-vrx derives from the panel's millimetres
/// (1 logical px = 1/6.299 mm, the density vrx_kit's metrics are in).
library;

class Display {
  const Display(this.name, this.width, this.height, this.widthMm, {this.touch = true});

  final String name;

  /// Pixels.
  final double width, height;

  /// The panel's width in mm (the connector's); 0 when it reports none,
  /// and flutter-vrx then keeps the pixel ratio at 1.0.
  final double widthMm;

  /// Fingers on it (the 9mm minimum is a promise there).
  final bool touch;

  double get pixelRatio => widthMm <= 0 ? 1.0 : width / widthMm / (160 / 25.4);

  @override
  String toString() => name;
}

/// The bench's 2.8" disp28a on the CM4: 480x640 portrait, 43x58mm.
const disp28a = Display('disp28a', 480, 640, 43);

/// The Raspberry Pi 7" touch display: 800x480, 154x86mm.
const dsi7 = Display('dsi7', 800, 480, 154);

/// A 7" HDMI panel: 1024x600, 154x86mm.
const hdmi7 = Display('hdmi7', 1024, 600, 154);

/// A 24" monitor over HDMI: 1920x1080, 527x296mm, mouse and keyboard.
const hdmi1080 = Display('hdmi1080', 1920, 1080, 527, touch: false);

/// A monitor whose EDID gives no size: 1280x720 at ratio 1.0.
const hdmiNoSize = Display('hdmi-nosize', 1280, 720, 0, touch: false);

/// Every display an applet's layout must hold on.
const allDisplays = [disp28a, dsi7, hdmi7, hdmi1080, hdmiNoSize];
