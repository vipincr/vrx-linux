// vrx_kit's half of the contract vectors (review step 44): each rule at
// least two languages read, and this file is the Dart reader for the
// allow-list's keys, the Facts reply's keys and the verdict words. The
// Rust readers live beside the rules they name; a vector this side
// disagrees with fails here, naming the key.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Matter allow-list keys vrx_kit spells are the vector\'s', () {
    final vector =
        jsonDecode(File('../../vectors/matter-allowlist.json').readAsStringSync())
            as Map<String, dynamic>;
    final keys = (vector['keys'] as Map<String, dynamic>).keys.toSet();
    final text = File('lib/src/matter.dart').readAsStringSync();
    for (final key in keys) {
      expect(text, contains("'$key'"),
          reason: 'vrx_kit no longer spells $key; the vector and the reader disagree');
    }
  });

  test('every Facts key the kit requires is the vector\'s', () {
    final vector =
        jsonDecode(File('../../vectors/facts-keys.json').readAsStringSync())
            as Map<String, dynamic>;
    final wire = (vector['keys'] as List).cast<String>().toSet();
    final text = File('lib/src/host.dart').readAsStringSync();
    final usb = File('lib/src/usb_host.dart').readAsStringSync();
    // the keys the strict readers require (SystemFacts and UsbHostState)
    final required = <String>{
      for (final m in RegExp(r"req\('(\w+)'").allMatches(text)) m.group(1)!,
      for (final m in RegExp(r"containsKey\('(\w+)'\)").allMatches(usb)) m.group(1)!,
    };
    expect(required, isNotEmpty, reason: 'run from the vrx_kit package root');
    final offWire = required.difference(wire);
    expect(offWire, isEmpty,
        reason: 'the kit requires keys the wire does not carry: $offWire');
  });

  test('the verdict words the kit reads are the vector\'s', () {
    final vector =
        jsonDecode(File('../../vectors/answer-verdict.json').readAsStringSync())
            as Map<String, dynamic>;
    final intent = (vector['intent_verdicts'] as List).cast<String>().toSet();
    final text = File('lib/src/host.dart').readAsStringSync();
    final read = RegExp(r"'(\w+)' => Verdict\.\w+")
        .allMatches(text)
        .map((m) => m.group(1)!)
        .toSet();
    expect(read, equals(intent),
        reason: 'the kit reads verdicts by kind; the words are the vector\'s');
    // the Answer call writes the answer vector's two words (channel.dart)
    final answer = (vector['answer_verdicts'] as List).cast<String>();
    final channel = File('lib/src/channel.dart').readAsStringSync();
    for (final word in answer) {
      expect(channel, contains("'$word'"),
          reason: 'the Answer call no longer spells $word');
    }
  });
}
