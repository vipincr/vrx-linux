import 'package:vrx_kit/vrx_kit.dart';

/// One package in the image and its licence.
class PackageLicence {
  const PackageLicence({required this.package, required this.version, required this.licence});

  final String package;
  final String version;

  /// SPDX expression, as Yocto records it.
  final String licence;
}

/// Parse Yocto's license.manifest: blocks of `KEY: value` lines
/// (PACKAGE NAME, PACKAGE VERSION, RECIPE NAME, LICENSE), blank-line
/// separated.
List<PackageLicence> parseManifest(String text) {
  final out = <PackageLicence>[];
  String? name, version, licence;
  void flush() {
    if (name != null) {
      out.add(PackageLicence(package: name!, version: version ?? '', licence: licence ?? ''));
    }
    name = version = licence = null;
  }

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      flush();
      continue;
    }
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final key = line.substring(0, colon).trim();
    final value = line.substring(colon + 1).trim();
    switch (key) {
      case 'PACKAGE NAME':
        name = value;
      case 'PACKAGE VERSION':
        version = value;
      case 'LICENSE':
        licence = value;
    }
  }
  flush();
  out.sort((a, b) => a.package.compareTo(b.package));
  return out;
}

enum DocsAction { init, loaded, opened, failed }

class DocsView {
  const DocsView({required this.packages, required this.open, required this.text, required this.error});

  final List<PackageLicence> packages;
  final PackageLicence? open;

  /// The open package's licence text, or null while loading.
  final String? text;
  final String? error;
}

class DocsModel extends StoreModel<DocsState, DocsAction, DocsView> {
  List<PackageLicence> packages = const [];
  PackageLicence? open;
  String? text;
  String? error;

  @override
  DocsState get initial => const DocsState();

  @override
  DocsAction get bootAction => DocsAction.init;

  @override
  DocsView reduce(DocsState state, DocsAction action) =>
      DocsView(packages: packages, open: open, text: text, error: error);

  @override
  DocsState get snapshot => const DocsState();
}

class DocsState {
  const DocsState();
}
