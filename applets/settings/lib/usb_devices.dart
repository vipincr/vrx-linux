import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

/// Settings > Device > USB devices (plan 0019 D11): what is plugged into
/// the board's host ports, read from vrxhost's facts. A drive can be
/// ejected; under the image's allow-list one switch stops anything new
/// from working; the footer says what the board's ports can and cannot
/// protect against. Offered only where the image declares a host port.
class UsbDevicesScreen extends StatelessWidget {
  const UsbDevicesScreen({
    super.key,
    required this.state,
    required this.supplyLow,
    required this.onEject,
    required this.onAllowNew,
    required this.onBack,
  });

  final UsbHostState state;

  /// The supply is below the board's alarm (null: no sensor).
  final bool? supplyLow;
  final void Function(UsbDevice) onEject;
  final void Function(bool on) onAllowNew;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    Widget sentence(String text) => Padding(
          padding: EdgeInsets.symmetric(horizontal: ScaledSpacing.of(context).inset, vertical: ScaledSpacing.of(context).xs),
          child: Text(text, style: TypeRole.subtext(context)),
        );
    final devices = state.devices;
    return VrxList(children: [
      VrxHeader(title: 'USB devices', onBack: onBack),
      if (state.policy == UsbPolicy.failed)
        sentence('The USB policy failed: nothing plugged in from now on will work until the device restarts.'),
      if (devices.isEmpty)
        sentence('Nothing is plugged in.')
      else
        for (final d in devices)
          VrxRow(
            label: usbDeviceLabel(d),
            detail: usbDeviceDetail(d, state.policy),
            value: d.mounts.isNotEmpty ? 'Eject' : '',
            valueGlyph: d.blocked ? VrxSymbols.warning : null,
            onTap: d.mounts.isNotEmpty ? () => onEject(d) : null,
          ),
      // the policy switch, only where an allow-list decides (plan 0019 D11)
      if (state.policy == UsbPolicy.allowlist)
        VrxRow(
          label: 'Allow new USB devices',
          value: state.allowNew ? 'On' : 'Off',
          widestValue: 'Off',
          onTap: () => onAllowNew(!state.allowNew),
        ),
      if (supplyLow == true && devices.any((d) => d.cls != UsbClass.hub))
        sentence('Power is low. A USB device may be drawing too much.'),
      for (final line in usbPortSentences(state)) sentence(line),
    ]);
  }
}

/// A device's row label: its own name, else what it is.
String usbDeviceLabel(UsbDevice d) => d.name.isNotEmpty ? d.name : usbClassWord(d.cls);

/// What kind of device it is, in a person's words.
String usbClassWord(UsbClass c) => switch (c) {
      UsbClass.hid => 'Keyboard or mouse',
      UsbClass.storage => 'Drive',
      UsbClass.audio => 'Audio device',
      UsbClass.video => 'Camera',
      UsbClass.serial => 'Serial adapter',
      UsbClass.hub => 'Hub',
      UsbClass.other => 'USB device',
    };

/// The row's second line: why it does not work, or what it is.
String usbDeviceDetail(UsbDevice d, UsbPolicy policy) {
  if (d.blocked) {
    return policy == UsbPolicy.failed ? 'Blocked: the USB policy is not running' : 'Blocked: this kind of device is not allowed here';
  }
  if (d.cls == UsbClass.storage && d.mounts.isEmpty) return 'Not readable: only FAT and exFAT drives open here';
  final speed = d.speed.isEmpty ? '' : ' · ${d.speed} Mb/s';
  return '${usbClassWord(d.cls)}$speed';
}

/// What the image declared about the ports' power (plan 0019 D12), as
/// sentences; an unknown says nothing.
List<String> usbPortSentences(UsbHostState s) => [
      if (s.vbus == 'unswitched')
        "The ports' power is not switched or limited: a device that draws too much can reset the board. Use a powered hub for hungry devices.",
      if (s.vbus == 'switched') 'The board switches the ports\' power.',
      if (s.vbus != 'unswitched' && s.overcurrent == 'none') 'An overload on a port is not reported.',
      if (s.overcurrent == 'reported') 'An overload on a port is reported here.',
    ];
