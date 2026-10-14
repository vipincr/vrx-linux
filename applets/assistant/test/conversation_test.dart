import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:assistant_applet/main.dart';
import 'package:assistant_applet/state.dart';

/// A chat whose answer arrives when the test says.
class _Chat extends LocalChat {
  // closed by the test when the answer is done
  // ignore: close_sinks
  final answer = StreamController<String>();
  @override
  Stream<String> reply(List<ChatTurn> turns, {int maxTokens = 256}) => answer.stream;
}

void main() {
  testWidgets('the conversation follows the answer, stops while the person reads back, and follows again at the bottom',
      (tester) async {
    tester.view.physicalSize = Size(disp28a.width, disp28a.height);
    tester.view.devicePixelRatio = disp28a.pixelRatio;
    addTearDown(tester.view.reset);
    final chat = _Chat();
    final model = AssistantModel()
      ..canSpeak = true
      ..turns = [
        for (var i = 0; i < 6; i++) ...[
          ChatTurn(ChatRole.user, 'Question $i, long enough to take a couple of lines on this panel?'),
          ChatTurn(ChatRole.assistant, 'Answer $i, which runs on for a while so that the list is taller than the screen.'),
        ],
      ];
    final applet = AssistantApplet(model, chat: chat);
    await tester.pumpWidget(AppletHost(applet: applet, actions: applet.events.stream));
    await tester.pump();

    ScrollPosition position() => tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    Future<void> write(String piece) async {
      chat.answer.add(piece);
      await tester.pump();
      await tester.pump();
    }

    applet.ask('Where does the answer go?');
    await tester.pump();
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await write('More of the answer, line $i. ');
    }
    expect(position().pixels, position().maxScrollExtent, reason: 'the newest words are in view');

    // the person reads back: following stops
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    final reading = position().pixels;
    expect(reading, lessThan(position().maxScrollExtent));
    for (var i = 0; i < 4; i++) {
      await write('Still more, line $i. ');
    }
    expect(position().pixels, reading, reason: 'the place being read stays put');

    // back at the bottom: it follows again
    await tester.drag(find.byType(ListView), const Offset(0, -5000));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await write('And the end, line $i. ');
    }
    expect(position().pixels, position().maxScrollExtent);
    await chat.answer.close();
    await applet.events.close();
    await tester.pump();
  });
}
