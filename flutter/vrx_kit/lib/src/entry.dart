/// Screens every applet would otherwise write again: entering a line of
/// text, and choosing a time zone.
library;

import 'package:flutter/material.dart';

import 'components.dart';
import 'input.dart';
import 'keyboard.dart';
import 'metrics.dart';
import 'symbols.dart';
import 'chrome.dart';
import 'scale.dart';
import 'shell.dart';
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

  Widget _field(BuildContext context, {required String? hint, required bool lines}) {
    final colors = VrxTheme.of(context);
    final space = ScaledSpacing.of(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => TextField(
        controller: _controller,
        showCursor: true,
        autofocus: true,
        obscureText: widget.obscure,
        // the on-screen keyboard edits; selection handles would only be
        // a stray control on the panel
        enableInteractiveSelection: false,
        onSubmitted: (_) => _done(),
        style: TypeRole.body(context),
        decoration: InputDecoration(
          // the field is a control too: a touch minimum tall
          constraints: BoxConstraints(minHeight: space.touch),
          hintText: hint,
          hintStyle: TypeRole.body(context).copyWith(color: colors.textSecondary),
          helperText: lines ? widget.helper?.call(_controller.text) : null,
          errorText: lines ? widget.error : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    // a display too short for the field, the keyboard and the shell's
    // strip (the 58mm disp28a) gives the entry the whole screen; decided
    // on the display, so having it cannot change the decision
    final view = View.of(context);
    final screen = view.physicalSize.height / view.devicePixelRatio;
    final least = VrxKeyboard.heightOf(context) + space.touch + Strokes.hairline;
    final entry = _layout(context);
    return screen - VrxStatusStrip.heightOf(context) < least ? VrxNoChrome(child: entry) : entry;
  }

  Widget _layout(BuildContext context) {
    final space = ScaledSpacing.of(context);
    final colors = VrxTheme.of(context);
    return LayoutBuilder(builder: (context, box) {
      // a header, a field and the keyboard's four rows, each the touch
      // minimum: on a panel too short for all of them (the 58mm
      // disp28a) the field takes the header's place beside Back and the
      // title (or an error) the line under it
      final rows = 6 * (space.touch + space.xs);
      if (box.maxHeight >= rows + space.touch) {
        return Column(children: [
          VrxHeader(title: widget.title, onBack: widget.onBack),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: space.md),
              child: Center(child: _field(context, hint: widget.hint, lines: true)),
            ),
          ),
          VrxKeyboard(controller: _controller, onDone: _done),
        ]);
      }
      return VrxBackOffer(
        onBack: widget.onBack,
        child: Column(children: [
          SizedBox(
            height: space.touch,
            child: Row(children: [
              VrxIconButton(glyph: VrxSymbols.arrow_back, onTap: widget.onBack),
              SizedBox(width: space.xs),
              Expanded(child: _field(context, hint: widget.hint ?? widget.title, lines: false)),
              SizedBox(width: space.inset),
            ]),
          ),
          Divider(height: Strokes.hairline, thickness: Strokes.hairline, color: colors.outlineFaint),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: space.inset),
              child: Align(
                alignment: Alignment.centerLeft,
                // an error, else what the field is for
                child: widget.error != null
                    ? VrxFitText(
                        widget.error!,
                        style: TypeRole.caption(context).copyWith(color: Theme.of(context).colorScheme.error),
                      )
                    : VrxFitText(widget.title, style: TypeRole.caption(context)),
              ),
            ),
          ),
          VrxKeyboard(controller: _controller, onDone: _done),
        ]),
      );
    });
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
    final cities = region == null
        ? const <String>[]
        : [
            for (final z in widget.zones)
              if (z.startsWith('$region/')) z
          ];
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
