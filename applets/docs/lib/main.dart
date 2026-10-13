import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

/// Where Yocto puts the image's licences (COPY_LIC_MANIFEST, COPY_LIC_DIRS).
const _root = '/usr/share/common-licenses';

final _events = StreamController<DocsAction>();

/// Licences: every package the image carries, its version and licence,
/// and each licence's text, from Yocto's own records in the image.
class DocsApplet extends Applet<DocsState, DocsAction, DocsView> {
  DocsApplet(this.model);

  final DocsModel model;

  @override
  DocsState get initial => model.initial;

  @override
  DocsAction get bootAction => model.bootAction;

  @override
  DocsView reduce(DocsState state, DocsAction action) => model.reduce(state, action);

  @override
  DocsState get snapshot => model.snapshot;

  Future<void> _openPackage(PackageLicence p) async {
    model
      ..open = p
      ..text = null;
    _events.add(DocsAction.opened);
    try {
      final dir = Directory('$_root/${p.package}');
      final texts = <String>[];
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is File) texts.add('── ${f.uri.pathSegments.last} ──\n\n${await f.readAsString()}');
        }
      }
      model.text = texts.isEmpty ? 'Licence: ${p.licence}' : texts.join('\n\n');
    } on FileSystemException catch (err) {
      model.text = 'Licence: ${p.licence}\n\n(${err.message})';
    }
    _events.add(DocsAction.opened);
  }

  @override
  Widget build(BuildContext context, DocsView view) {
    final open = view.open;
    return Scaffold(
      body: SafeArea(
        child: open == null
            ? CustomScrollView(slivers: [
                SliverList.list(children: [
                  const VrxHeader(title: 'Licences', onBack: Nav.pop),
                  if (view.error != null) VrxBanner(text: view.error),
                ]),
                // hundreds of packages: built as they scroll in
                SliverList.builder(
                  itemCount: view.packages.length,
                  itemBuilder: (context, i) {
                    final p = view.packages[i];
                    return VrxRow(label: p.package, value: p.licence, onTap: () => unawaited(_openPackage(p)));
                  },
                ),
              ])
            : Column(children: [
                VrxHeader(
                  title: open.package,
                  onBack: () {
                    model.open = null;
                    _events.add(DocsAction.opened);
                  },
                ),
                Expanded(
                  child: view.text == null
                      ? const Center(child: CircularProgressIndicator())
                      : SingleChildScrollView(
                          padding: EdgeInsets.all(ScaledSpacing.of(context).md),
                          child: Text(view.text!, style: TypeRole.subtext(context)),
                        ),
                ),
              ]),
      ),
    );
  }
}

Future<void> main() async {
  final model = DocsModel();
  runApplet(DocsApplet(model), actions: _events.stream);
  try {
    model.packages = parseManifest(await File('$_root/license.manifest').readAsString());
    _events.add(DocsAction.loaded);
  } on FileSystemException catch (err) {
    model.error = 'No licence manifest in this image (${err.message})';
    _events.add(DocsAction.failed);
  }
}
