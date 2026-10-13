import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:docs_applet/main.dart';
import 'package:docs_applet/state.dart';

/// The Licences screens hold on every display vrx drives (vrx_check).
void main() {
  const packages = [
    PackageLicence(package: 'base-files', version: '3.0.14', licence: 'GPL-2.0-only'),
    PackageLicence(package: 'linux-firmware-rpidistro-bcm43455', version: '20240411+1.0', licence: 'Firmware-broadcom_bcm43xx & WHENCE'),
    PackageLicence(package: 'zsh', version: '5.9', licence: 'zsh'),
  ];
  for (final display in allDisplays) {
    testWidgets('docs list on ${display.name}', (tester) async {
      await expectCleanLayout(tester, DocsApplet(DocsModel()..packages = packages), display: display);
    });
    testWidgets('docs licence on ${display.name}', (tester) async {
      final model = DocsModel()
        ..packages = packages
        ..open = packages[1]
        ..text = 'Copyright (c) Broadcom. Redistribution and use in binary form, without modification, are permitted.';
      await expectCleanLayout(tester, DocsApplet(model), display: display);
    });
  }
}
