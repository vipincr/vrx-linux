// The wire has one spelling (KRN-04, review 2026-10-17): the Rust IDL.
// This test reads vectors/host-wire.json (generated from that IDL; the
// Rust side's dispatch test holds the same file to the IDL) and checks
// every io.vrx.Host name the kit spells against it. Renaming a method or
// an error in either language fails the test that names the gap; a name
// the kit spells that the IDL does not declare is a call that can only
// ever answer MethodNotFound.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final vector =
      jsonDecode(File('../../vectors/host-wire.json').readAsStringSync())
          as Map<String, dynamic>;
  final methods = (vector['methods'] as List).cast<String>();
  final errors = (vector['errors'] as List).cast<String>();

  test('every io.vrx.Host name the kit spells is the IDL\'s', () {
    final src = Directory('lib/src')
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .toList()
      ..sort();
    expect(src, isNotEmpty, reason: 'run from the vrx_kit package root');
    final unknown = <String, String>{};
    for (final path in src) {
      final text = File(path).readAsStringSync();
      for (final m in RegExp(r'io\.vrx\.Host\.(\w+)').allMatches(text)) {
        final name = m.group(1)!;
        if (!methods.contains(name) && !errors.contains(name)) {
          unknown[name] = path;
        }
      }
    }
    expect(
      unknown,
      isEmpty,
      reason:
          'names the IDL does not declare (vectors/host-wire.json is the '
          'wire; regenerate it from rust/host/src/varlink.rs if the IDL '
          'moved): $unknown',
    );
  });

}
