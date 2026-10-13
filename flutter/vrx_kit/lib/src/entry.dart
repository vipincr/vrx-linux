/// Screens every applet would otherwise write again: entering a line of
/// text, and choosing a time zone.
library;

import 'package:flutter/material.dart';

import 'components.dart';
import 'keyboard.dart';
import 'scale.dart';
import 'theme.dart';

/// A line of text: a header, the field, and the on-screen keyboard under
/// it. A physical keyboard types into the field directly (the on-screen
/// one steps aside while it does); Enter or the keyboard's done key ends
/// it with the text.
class VrxTextEntry extends StatefulWidget {
  const VrxTextEntry({
    super.key,
    required this.title,
    this.initial = '',
    this.hint,
    this.helper,
    this.error,
    this.obscure = false,
    required this.onBack,
    required this.onDone,
  });

  final String title;
  final String initial;

  /// An example, drawn dimmed so an empty field never looks filled.
  final String? hint;

  /// A line under the field that follows the text as it is typed.
  final String Function(String text)? helper;
  final String? error;

  /// A passphrase: dots, not letters.
  final bool obscure;
  final VoidCallback onBack;
  final void Function(String text) onDone;

  @override
  State<VrxTextEntry> createState() => _VrxTextEntryState();
}

class _VrxTextEntryState extends State<VrxTextEntry> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _done() => widget.onDone(_controller.text);

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    final palette = VrxTheme.of(context);
    // a 58mm-tall panel holds the header, one dense field and the four
    // 9mm keyboard rows with nothing to spare: no floating label, no
    // spacer (the bench cut the keyboard's last row off)
    return Column(children: [
      VrxHeader(title: widget.title, onBack: widget.onBack),
      Expanded(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: space.md),
          child: Center(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => TextField(
                controller: _controller,
                showCursor: true,
                autofocus: true,
                obscureText: widget.obscure,
                onSubmitted: (_) => _done(),
                style: TypeRole.body(context),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.hint,
                  hintStyle: TypeRole.body(context).copyWith(color: palette.faint),
                  helperText: widget.helper?.call(_controller.text),
                  errorText: widget.error,
                ),
              ),
            ),
          ),
        ),
      ),
      VrxKeyboard(controller: _controller, onDone: _done),
    ]);
  }
}

/// Time zone regions as a person reads them: "Indian" is the ocean.
const vrxZoneRegions = {
  'Africa': 'Africa',
  'America': 'Americas',
  'Antarctica': 'Antarctica',
  'Arctic': 'Arctic',
  'Asia': 'Asia',
  'Atlantic': 'Atlantic Ocean',
  'Australia': 'Australia',
  'Europe': 'Europe',
  'Indian': 'Indian Ocean',
  'Pacific': 'Pacific Ocean',
};

/// "Europe/London" -> "London": a database key is not a place name.
String vrxCityOf(String zone) => zone.split('/').last.replaceAll('_', ' ');

/// Choose a time zone: a dozen regions, then that region's cities,
/// because 400 zones is not a list anyone scrolls on a hand-held panel.
/// [zones] are IANA names (timedated's list); empty shows it loading.
class VrxZonePicker extends StatefulWidget {
  const VrxZonePicker({
    super.key,
    required this.title,
    required this.zones,
    this.current = '',
    required this.onBack,
    required this.onPick,
  });

  final String title;
  final List<String> zones;
  final String current;
  final VoidCallback onBack;
  final void Function(String zone) onPick;

  @override
  State<VrxZonePicker> createState() => _VrxZonePickerState();
}

class _VrxZonePickerState extends State<VrxZonePicker> {
  String? _region;

  @override
  Widget build(BuildContext context) {
    final region = _region;
    final regions = [
      for (final r in vrxZoneRegions.keys)
        if (widget.zones.any((z) => z.startsWith('$r/'))) r,
    ];
    final cities = region == null ? const <String>[] : [for (final z in widget.zones) if (z.startsWith('$region/')) z];
    final currentRegion = widget.current.split('/').first;
    return Column(children: [
      VrxHeader(
        title: region == null ? widget.title : vrxZoneRegions[region] ?? region,
        // back from the cities is the regions; from the regions, out
        onBack: region == null ? widget.onBack : () => setState(() => _region = null),
      ),
      Expanded(
        child: widget.zones.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : region == null
                ? ListView.builder(
                    itemCount: regions.length,
                    itemBuilder: (context, i) => VrxRow(
                      label: vrxZoneRegions[regions[i]] ?? regions[i],
                      value: regions[i] == currentRegion ? 'Current' : null,
                      onTap: () => setState(() => _region = regions[i]),
                    ),
                  )
                // hundreds of cities: built as they scroll in
                : ListView.builder(
                    itemCount: cities.length,
                    itemBuilder: (context, i) => VrxRow(
                      label: vrxCityOf(cities[i]),
                      value: cities[i] == widget.current ? 'Current' : null,
                      onTap: () => widget.onPick(cities[i]),
                    ),
                  ),
      ),
    ]);
  }
}
