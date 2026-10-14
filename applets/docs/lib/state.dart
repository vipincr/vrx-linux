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

/// Everything the applet reacts to (plan 0013 D1: the reducer is the only
/// writer): a signal, or what was read, as data.
sealed class DocsAction {
  const DocsAction();

  static const init = DocsSignal.init;
  static const back = DocsSignal.back;
}

enum DocsSignal implements DocsAction { init, back }

/// The list read from the image, or the reason it could not be.
final class DocsLoaded implements DocsAction {
  const DocsLoaded({this.packages = const [], this.error});

  final List<PackageLicence> packages;
  final String? error;
}

/// A package was opened; its text is read next.
final class DocsOpened implements DocsAction {
  const DocsOpened(this.package);

  final PackageLicence package;
}

/// A package's licence text arrived (dropped if another is open by now).
final class DocsText implements DocsAction {
  const DocsText(this.package, this.text);

  final PackageLicence package;
  final String text;
}

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
  DocsView reduce(DocsState state, DocsAction action) {
    switch (action) {
      case DocsLoaded(:final packages, :final error):
        this.packages = packages;
        this.error = error;
      case DocsOpened(:final package):
        open = package;
        text = null;
      case DocsText(:final package, :final text):
        if (identical(open, package)) this.text = text;
      case DocsSignal.back:
        open = null;
        text = null;
      case DocsSignal.init:
        break;
    }
    return DocsView(packages: packages, open: open, text: text, error: error);
  }

  @override
  DocsState get snapshot => const DocsState();

  /// The list is read again at every start; nothing is kept.
  @override
  void restore(DocsState snapshot) {}

  @override
  DocsAction get backAction => DocsAction.back;

  @override
  bool get atRoot => open == null;

  // the package list, or one package's licence text
  @override
  Object get screen => open?.package ?? 0;

  @override
  Object? get fingerprint => [for (final p in packages) p.package, open?.package, text, error];
}

class DocsState {
  const DocsState();
}
