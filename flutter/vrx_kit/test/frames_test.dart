import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

void main() {
  test('percentiles are nearest rank, and over-budget frames are counted per phase', () {
    final w = FrameWindow();
    w.build.addAll([1000, 2000, 3000, 4000, 20000]);
    w.raster.addAll([500, 500, 500, 30000, 500]);
    final s = w.summary(route: 'alarms', budgetUs: 16667);
    expect(s['frames'], 5);
    expect(s['build_p50_us'], 3000);
    expect(s['build_p95_us'], 20000);
    expect(s['raster_p99_us'], 30000);
    expect(s['over_build'], 1);
    expect(s['over_raster'], 1);
    expect(s['route'], 'alarms');
    expect(s['budget_us'], 16667);
  });

  test('an empty window has no percentile, and is empty', () {
    final w = FrameWindow();
    expect(w.isEmpty, isTrue);
    expect(FrameWindow.percentile(const [], 95), 0);
  });
}
