import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// A stand-in timedated: holds a zone, refuses SetTimezone for "Mars/*"
/// the way timedated refuses an unauthorised caller.
class _FakeTimedate extends DBusObject {
  _FakeTimedate() : super(DBusObjectPath('/org/freedesktop/timedate1'));

  String zone = 'UTC';

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse({
        'Timezone': DBusString(zone),
        'NTP': const DBusBoolean(true),
        'NTPSynchronized': const DBusBoolean(false),
      });

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.name == 'SetTimezone') {
      final wanted = call.values.first.asString();
      if (wanted.startsWith('Mars/')) {
        return DBusMethodErrorResponse.accessDenied('not authorised');
      }
      zone = wanted;
      await emitPropertiesChanged('org.freedesktop.timedate1',
          changedProperties: {'Timezone': DBusString(zone)});
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

void main() {
  test('the network name follows the person name', () {
    expect(hostnameFor('Vipin\'s Clock'), 'vipin-s-clock');
    expect(hostnameFor('  --  '), 'vrx');
    expect(hostnameFor('a' * 80).length, 63);
  });

  test('time over D-Bus: live state, a change, and a refusal by name', () async {
    final dir = await Directory.systemTemp.createTemp('vrx-bus');
    final server = DBusServer();
    final address = await server.listenAddress(DBusAddress.unix(dir: dir));
    final serviceBus = DBusClient(address);
    final fake = _FakeTimedate();
    await serviceBus.requestName('org.freedesktop.timedate1');
    await serviceBus.registerObject(fake);

    final time = DBusTimeService(DBusClient(address));
    final states = StreamIterator(time.watch());
    expect(await states.moveNext(), isTrue);
    expect(states.current.zone, 'UTC');
    expect(states.current.automatic, isTrue);

    await time.setZone('Asia/Kolkata');
    expect(await states.moveNext(), isTrue);
    expect(states.current.zone, 'Asia/Kolkata');

    await expectLater(
      time.setZone('Mars/Olympus'),
      throwsA(isA<SystemError>().having((e) => e.denied, 'denied', isTrue)),
    );
    await states.cancel();
    await serviceBus.close();
    await server.close();
    // the dbus package speaks the bus protocol on Linux (and Windows);
    // on a developer's macOS host its connection never completes
  }, skip: Platform.isLinux ? false : 'the dbus package supports Linux only');
}
