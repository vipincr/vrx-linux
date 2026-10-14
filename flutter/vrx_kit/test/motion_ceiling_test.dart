import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/src/motion.dart';
import 'package:vrx_kit/src/ui_standard.g.dart';

/// G051 (plan 0017 D11a): no motion is slower than its ceiling. Every row of the overlay's [ceiling.*] is
/// integrated through the engine at its reference travel on the 480 px reference display and must arrive (first
/// within a tenth of the target) and settle (within half a pixel and 5 px/s for good) inside its numbers. A token
/// swap or a stiffness edit that makes a motion slower fails here, before it reaches a board.
void main() {
  test('there is a ceiling for every motion a person waits on', () {
    final rows = vrxCeilings.map((c) => c.row).toSet();
    for (final row in [
      VrxMicro.press,
      VrxMicro.drawerOpen,
      VrxMicro.drawerClose,
      VrxMicro.screen,
      VrxMicro.applet,
      VrxMicro.modal,
      VrxMicro.banner,
      VrxMicro.list,
      VrxMicro.select,
      VrxMicro.overscroll,
      VrxMicro.key,
    ]) {
      expect(rows, contains(row), reason: 'no [ceiling] names $row');
    }
  });

  for (final c in vrxCeilings) {
    test('${c.name}: arrives within ${c.arriveMs} ms and settles within ${c.settleMs} ms over ${c.travelPx} px', () {
      final spring = VrxSpring.micro(c.row, follow: c.useFollow);
      final m = vrxMeasure(spring, c.travelPx, VrxUnit.px());
      expect(m.arriveMs, lessThanOrEqualTo(c.arriveMs), reason: '$spring arrives at ${m.arriveMs.toStringAsFixed(0)} ms');
      expect(m.settleMs, lessThanOrEqualTo(c.settleMs), reason: '$spring settles at ${m.settleMs.toStringAsFixed(0)} ms');
      expect(m.arriveMs, lessThanOrEqualTo(m.settleMs));
    });
  }

  test('the engine never builds a simulation at Flutter\'s default tolerance', () {
    for (final set in VrxSpringSet.values) {
      for (final token in VrxSpringToken.values) {
        for (final unit in [VrxUnit.px(), VrxUnit.fractionOf(300), VrxUnit.alpha]) {
          final tol = vrxSimulate(VrxSpring(set, token), 0, 1, 0, unit).tolerance;
          expect(tol.distance, isNot(0.001));
          expect(tol.velocity, isNot(0.001));
        }
      }
    }
  });

  test('the list enters 16 ms apart and no row past the eighth is delayed', () {
    final row = vrxMicro[VrxMicro.list]!;
    expect(row.staggerMs, 16);
    expect(row.shiftPx, 8);
  });
}
