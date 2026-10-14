import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:assistant_applet/main.dart';
import 'package:assistant_applet/state.dart';

void main() {
  testWidgets('"Listening…" appears only once stt says its microphone is open', (tester) async {
    tester.view.physicalSize = Size(disp28a.width, disp28a.height);
    tester.view.devicePixelRatio = disp28a.pixelRatio;
    addTearDown(tester.view.reset);
    final model = AssistantModel()
      ..canSpeak = true
      ..preparing = true;
    final applet = AssistantApplet(model);
    await tester.pumpWidget(AppletHost(applet: applet, actions: applet.events.stream));
    await tester.pump();
    expect(find.text('Opening the mic…'), findsOneWidget);
    expect(find.text('Listening…'), findsNothing);

    applet.recording();
    await tester.pump();
    await tester.pump();
    expect(find.text('Listening…'), findsOneWidget);

    applet.heard({'error': 'nothing-heard'});
    await tester.pump();
    await tester.pump();
    expect(find.text('Listening…'), findsNothing);
    expect(find.text('Nothing was heard.'), findsOneWidget);
    await applet.events.close();
  });
}
