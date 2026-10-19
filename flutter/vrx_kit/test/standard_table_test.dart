// The metrics' density is the shared table's (KRN-04, review
// 2026-10-17): displays.json's `standard` row is the one spelling, the
// Rust console check's twin test holds its consts to the same row, and
// this test holds mmToDp and ptToDp to it. The constants stay const
// (Spacing's static consts need them); the tests make drift impossible
// without a failure that names the row.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart' show mmToDp, ptToDp;

void main() {
  test('mmToDp and ptToDp are the shared table\'s standard row', () {
    final table =
        jsonDecode(File('../vrx_check/lib/displays.json').readAsStringSync())
            as Map<String, dynamic>;
    final standard = table['standard'] as Map<String, dynamic>;
    final dpPerInch = (standard['dp_per_inch'] as num).toDouble();
    final bodyPt = (standard['body_pt'] as num).toDouble();
    expect(mmToDp * 25.4, closeTo(dpPerInch, 1e-9),
        reason: 'metrics.dart mmToDp and the table disagree');
    expect(ptToDp * 72.0, closeTo(dpPerInch, 1e-9),
        reason: 'metrics.dart ptToDp and the table disagree');
    // the body text the Rust console check lays out at is the standard's
    expect(bodyPt, greaterThan(0));
  });
}
