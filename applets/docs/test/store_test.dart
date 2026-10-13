import 'package:flutter_test/flutter_test.dart';

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
}
