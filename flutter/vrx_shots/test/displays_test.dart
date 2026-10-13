import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_shots/vrx_shots.dart';

void main() {
  test('the displays carry the runtime pixel ratio: px per mm over 160/25.4', () {
    // the disp28a: 480 px over 43 mm; a 24" monitor: 1920 px over 527 mm
    expect(disp28a.pixelRatio, closeTo(480 / 43 / (160 / 25.4), 0.01));
    expect(hdmi1080.pixelRatio, closeTo(1920 / 527 / (160 / 25.4), 0.01));
  });
}
