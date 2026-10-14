import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:docs_applet/state.dart';

void main() {
  test('the Yocto license manifest parses into sorted packages', () {
    const manifest = '''
PACKAGE NAME: zlib
PACKAGE VERSION: 1.3.1
RECIPE NAME: zlib
LICENSE: Zlib

PACKAGE NAME: bash
PACKAGE VERSION: 5.2.37
RECIPE NAME: bash
LICENSE: GPL-3.0-or-later
''';
    final packages = parseManifest(manifest);
    expect(packages.map((p) => p.package), ['bash', 'zlib']);
    expect(packages.first.licence, 'GPL-3.0-or-later');
    expect(packages.last.version, '1.3.1');
  });

  test("opening, reading and Back go through the store, and its promises hold (plan 0013 D1, D2)", () {
    final h = StoreHarness(DocsModel());
    final zlib = parseManifest('PACKAGE NAME: zlib\nPACKAGE VERSION: 1\nLICENSE: Zlib\n').single;
    h.dispatch(DocsLoaded(packages: [zlib]));
    h.dispatch(DocsOpened(zlib));
    h.assertView((v) => v.open == zlib && v.text == null, because: 'loading');
    h.dispatch(DocsText(zlib, 'the text'));
    h.assertView((v) => v.text == 'the text');
    h.dispatch(DocsAction.back);
    h.dispatch(DocsText(zlib, 'late'));
    h.assertView((v) => v.open == null && v.text == null, because: 'a late text for a closed package is dropped');
    h.dispatch(DocsOpened(zlib));
    h.verify(fresh: DocsModel.new, probes: [DocsAction.back, DocsText(zlib, 'x')]);
  });
}
