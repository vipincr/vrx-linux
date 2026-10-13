/// A QR code, drawn by the kit (plan 0011 D15): an instrument for an
/// address a phone should open, or a Wi-Fi network it should join. The
/// encoder is the kit's own because the pub `qr` package is not in the
/// offline build's archive: byte mode, error correction M (about 15 %),
/// versions 1 to 10 (up to 213 bytes, more than an address or a WIFI:
/// string needs), the mask with the lowest penalty (ISO/IEC 18004 §8.8).
/// Checked module by module against an independent encoder in the tests.
library;

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// A QR symbol: [size] x [size] modules, true for dark.
class VrxQrCode {
  VrxQrCode._(this.version, this.mask, this.modules);

  final int version;
  final int mask;
  final List<List<bool>> modules;

  int get size => modules.length;

  bool dark(int row, int col) => modules[row][col];

  /// Encode [text] (UTF-8). [mask] forces one of the eight masks;
  /// otherwise the one with the lowest penalty. Throws a [FormatException]
  /// when it does not fit version 10.
  factory VrxQrCode.encode(String text, {int? mask}) {
    final data = _utf8(text);
    for (var v = 1; v <= 10; v++) {
      final b = _blocks[v - 1];
      final capacity = b.dataCodewords;
      final countBits = v <= 9 ? 8 : 16;
      if (4 + countBits + data.length * 8 > capacity * 8) continue;
      final bits = _Bits()
        ..add(0x4, 4)
        ..add(data.length, countBits);
      for (final byte in data) {
        bits.add(byte, 8);
      }
      final room = capacity * 8 - bits.length;
      bits.add(0, room < 4 ? room : 4);
      if (bits.length % 8 != 0) bits.add(0, 8 - bits.length % 8);
      final codewords = bits.bytes();
      for (var pad = 0xEC; codewords.length < capacity; pad ^= 0xEC ^ 0x11) {
        codewords.add(pad);
      }
      final all = _interleave(v, codewords);
      final base = _Matrix(v)..drawFunction();
      base.drawCodewords(all);
      if (mask != null) return VrxQrCode._(v, mask, (base.copy()..apply(mask)).modules);
      var best = -1, bestScore = 1 << 30;
      List<List<bool>>? bestModules;
      for (var m = 0; m < 8; m++) {
        final t = base.copy()..apply(m);
        final score = t.penalty();
        if (score < bestScore) {
          best = m;
          bestScore = score;
          bestModules = t.modules;
        }
      }
      return VrxQrCode._(v, best, bestModules!);
    }
    throw const FormatException('too long for a QR code of version 10');
  }
}

List<int> _utf8(String s) {
  final out = <int>[];
  for (final r in s.runes) {
    if (r < 0x80) {
      out.add(r);
    } else if (r < 0x800) {
      out.addAll([0xC0 | r >> 6, 0x80 | r & 0x3F]);
    } else if (r < 0x10000) {
      out.addAll([0xE0 | r >> 12, 0x80 | r >> 6 & 0x3F, 0x80 | r & 0x3F]);
    } else {
      out.addAll([0xF0 | r >> 18, 0x80 | r >> 12 & 0x3F, 0x80 | r >> 6 & 0x3F, 0x80 | r & 0x3F]);
    }
  }
  return out;
}

class _Bits {
  final _bits = <bool>[];
  int get length => _bits.length;

  void add(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      _bits.add((value >> i) & 1 == 1);
    }
  }

  List<int> bytes() => [
        for (var i = 0; i < _bits.length; i += 8)
          [for (var j = 0; j < 8; j++) _bits[i + j] ? 1 << (7 - j) : 0].reduce((a, b) => a | b),
      ];
}

/// Error correction M, versions 1-10: EC codewords per block, and the
/// blocks' data lengths (ISO/IEC 18004 Table 9).
class _Block {
  const _Block(this.ec, this.data);
  final int ec;
  final List<int> data;
  int get dataCodewords => data.reduce((a, b) => a + b);
}

const _blocks = [
  _Block(10, [16]),
  _Block(16, [28]),
  _Block(26, [44]),
  _Block(18, [32, 32]),
  _Block(24, [43, 43]),
  _Block(16, [27, 27, 27, 27]),
  _Block(18, [31, 31, 31, 31]),
  _Block(22, [38, 38, 39, 39]),
  _Block(22, [36, 36, 36, 37, 37]),
  _Block(26, [43, 43, 43, 43, 44]),
];

/// Alignment pattern centres (Annex E).
const _align = [
  <int>[],
  [6, 18],
  [6, 22],
  [6, 26],
  [6, 30],
  [6, 34],
  [6, 22, 38],
  [6, 24, 42],
  [6, 26, 46],
  [6, 28, 50],
];

/// Remainder bits after the codewords (Table 1).
const _remainder = [0, 7, 7, 7, 7, 7, 0, 0, 0, 0];

// ── Reed-Solomon over GF(256), x^8 + x^4 + x^3 + x^2 + 1 ───────────────

int _mul(int x, int y) {
  var z = 0;
  for (var i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >> 7) * 0x11D);
    z ^= ((y >> i) & 1) * x;
  }
  return z & 0xFF;
}

List<int> _divisor(int degree) {
  final r = List<int>.filled(degree, 0)..[degree - 1] = 1;
  var root = 1;
  for (var i = 0; i < degree; i++) {
    for (var j = 0; j < r.length; j++) {
      r[j] = _mul(r[j], root);
      if (j + 1 < r.length) r[j] ^= r[j + 1];
    }
    root = _mul(root, 0x02);
  }
  return r;
}

List<int> _ecc(List<int> data, int degree) {
  final div = _divisor(degree);
  final r = List<int>.filled(degree, 0, growable: true);
  for (final b in data) {
    final factor = b ^ r.removeAt(0);
    r.add(0);
    for (var i = 0; i < r.length; i++) {
      r[i] ^= _mul(div[i], factor);
    }
  }
  return r;
}

/// The data blocks, each with its EC, interleaved (§8.6).
List<int> _interleave(int version, List<int> codewords) {
  final b = _blocks[version - 1];
  final data = <List<int>>[];
  var at = 0;
  for (final n in b.data) {
    data.add(codewords.sublist(at, at + n));
    at += n;
  }
  final ecc = [for (final d in data) _ecc(d, b.ec)];
  final longest = b.data.reduce((x, y) => x > y ? x : y);
  return [
    for (var i = 0; i < longest; i++)
      for (final d in data)
        if (i < d.length) d[i],
    for (var i = 0; i < b.ec; i++)
      for (final e in ecc) e[i],
  ];
}

// ── the matrix ─────────────────────────────────────────────────────────

class _Matrix {
  _Matrix(this.version)
      : modules = List.generate(17 + 4 * version, (_) => List.filled(17 + 4 * version, false)),
        function = List.generate(17 + 4 * version, (_) => List.filled(17 + 4 * version, false));

  _Matrix._copy(this.version, this.modules, this.function);

  final int version;
  final List<List<bool>> modules;
  final List<List<bool>> function;
  int get size => modules.length;

  _Matrix copy() => _Matrix._copy(version, [for (final r in modules) List.of(r)], function);

  void _set(int row, int col, bool dark) {
    modules[row][col] = dark;
    function[row][col] = true;
  }

  void drawFunction() {
    for (var i = 0; i < size; i++) {
      _set(6, i, i.isEven);
      _set(i, 6, i.isEven);
    }
    _finder(3, 3);
    _finder(3, size - 4);
    _finder(size - 4, 3);
    final a = _align[version - 1];
    for (var i = 0; i < a.length; i++) {
      for (var j = 0; j < a.length; j++) {
        if ((i == 0 && j == 0) || (i == 0 && j == a.length - 1) || (i == a.length - 1 && j == 0)) continue;
        _alignment(a[i], a[j]);
      }
    }
    _format(0); // reserved now, written with the mask
    _version();
  }

  void _finder(int r, int c) {
    for (var dr = -4; dr <= 4; dr++) {
      for (var dc = -4; dc <= 4; dc++) {
        final rr = r + dr, cc = c + dc;
        if (rr < 0 || rr >= size || cc < 0 || cc >= size) continue;
        final d = dr.abs() > dc.abs() ? dr.abs() : dc.abs();
        _set(rr, cc, d != 2 && d != 4);
      }
    }
  }

  void _alignment(int r, int c) {
    for (var dr = -2; dr <= 2; dr++) {
      for (var dc = -2; dc <= 2; dc++) {
        final d = dr.abs() > dc.abs() ? dr.abs() : dc.abs();
        _set(r + dr, c + dc, d != 1);
      }
    }
  }

  void _format(int mask) {
    final data = 0 << 3 | mask; // M is 00
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final bits = (data << 10 | rem) ^ 0x5412;
    bool bit(int i) => (bits >> i) & 1 == 1;
    for (var i = 0; i <= 5; i++) {
      _set(i, 8, bit(i));
    }
    _set(7, 8, bit(6));
    _set(8, 8, bit(7));
    _set(8, 7, bit(8));
    for (var i = 9; i < 15; i++) {
      _set(8, 14 - i, bit(i));
    }
    for (var i = 0; i < 8; i++) {
      _set(8, size - 1 - i, bit(i));
    }
    for (var i = 8; i < 15; i++) {
      _set(size - 15 + i, 8, bit(i));
    }
    _set(size - 8, 8, true); // the dark module
  }

  void _version() {
    if (version < 7) return;
    var rem = version;
    for (var i = 0; i < 12; i++) {
      rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    }
    final bits = version << 12 | rem;
    for (var i = 0; i < 18; i++) {
      final dark = (bits >> i) & 1 == 1;
      final a = size - 11 + i % 3, b = i ~/ 3;
      _set(b, a, dark);
      _set(a, b, dark);
    }
  }

  void drawCodewords(List<int> data) {
    final total = data.length * 8 + _remainder[version - 1];
    var i = 0;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          final col = right - j;
          final upward = ((right + 1) & 2) == 0;
          final row = upward ? size - 1 - vert : vert;
          if (function[row][col] || i >= total) continue;
          modules[row][col] = i < data.length * 8 && (data[i >> 3] >> (7 - (i & 7))) & 1 == 1;
          i++;
        }
      }
    }
  }

  void apply(int mask) {
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        if (function[r][c]) continue;
        final flip = switch (mask) {
          0 => (r + c) % 2 == 0,
          1 => r % 2 == 0,
          2 => c % 3 == 0,
          3 => (r + c) % 3 == 0,
          4 => (r ~/ 2 + c ~/ 3) % 2 == 0,
          5 => r * c % 2 + r * c % 3 == 0,
          6 => (r * c % 2 + r * c % 3) % 2 == 0,
          _ => ((r + c) % 2 + r * c % 3) % 2 == 0,
        };
        if (flip) modules[r][c] = !modules[r][c];
      }
    }
    // the format with this mask, over the reserved copy
    final keep = [for (final row in function) List.of(row)];
    _format(mask);
    for (var r = 0; r < size; r++) {
      function[r].setAll(0, keep[r]);
    }
  }

  /// ISO/IEC 18004 §8.8.2: runs, 2x2 blocks, finder-like patterns, balance.
  /// The finder-like rule and the balance are read as segno reads them
  /// (the standard leaves room in both), so the mask chosen can be checked
  /// against an independent encoder; any mask reads.
  int penalty() {
    var score = 0;
    bool at(int r, int c) => modules[r][c];
    for (var pass = 0; pass < 2; pass++) {
      for (var a = 0; a < size; a++) {
        final seq = [for (var b = 0; b < size; b++) pass == 0 ? at(a, b) : at(b, a)];
        var run = 1;
        for (var b = 1; b <= size; b++) {
          if (b < size && seq[b] == seq[b - 1]) {
            run++;
          } else {
            if (run >= 5) score += run - 2;
            run = 1;
          }
        }
        score += _finderLike(seq);
      }
    }
    for (var r = 0; r + 1 < size; r++) {
      for (var c = 0; c + 1 < size; c++) {
        final v = at(r, c);
        if (v == at(r, c + 1) && v == at(r + 1, c) && v == at(r + 1, c + 1)) score += 3;
      }
    }
    var dark = 0;
    for (final row in modules) {
      for (final d in row) {
        if (d) dark++;
      }
    }
    final percent = dark * 100 / (size * size);
    return score + 10 * ((percent - 50).abs() / 5).floor();
  }

  /// 1011101 preceded or followed by up to four light modules (fewer at
  /// the symbol's edge), 40 each.
  int _finderLike(List<bool> seq) {
    const pattern = [true, false, true, true, true, false, true];
    int find(int from) {
      for (var i = from; i + 7 <= seq.length; i++) {
        var hit = true;
        for (var k = 0; k < 7 && hit; k++) {
          hit = seq[i + k] == pattern[k];
        }
        if (hit) return i;
      }
      return -1;
    }

    bool light(int from, int to) {
      for (var i = from < 0 ? 0 : from; i < to && i < seq.length; i++) {
        if (seq[i]) return false;
      }
      return true;
    }

    var count = 0;
    var idx = find(0);
    while (idx != -1) {
      var next = idx + 7;
      if (idx == 0 || idx == seq.length - 7 || light(idx - 4, idx) || light(next, next + 4)) {
        count += 40;
      } else {
        next = idx + 4;
      }
      idx = find(next);
    }
    return count;
  }
}

/// [code] drawn square in the space it is given, with its four-module
/// quiet zone, dark modules on light whatever the theme (a camera reads
/// dark on light).
class VrxQr extends StatelessWidget {
  const VrxQr({super.key, required this.data, this.label});

  final String data;

  /// What it holds, for a screen reader ("The address of this page").
  final String? label;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final code = VrxQrCode.encode(data);
    // the darker of the ink and the page is the module
    final inkDarker = colors.text.computeLuminance() < colors.page.computeLuminance();
    final darkColour = inkDarker ? colors.text : colors.page;
    final lightColour = inkDarker ? colors.page : colors.text;
    return Semantics(
      label: label ?? data,
      image: true,
      child: AspectRatio(
        aspectRatio: 1,
        child: CustomPaint(painter: _QrPainter(code, darkColour, lightColour)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.code, this.dark, this.light);

  final VrxQrCode code;
  final Color dark, light;

  @override
  void paint(Canvas canvas, Size size) {
    final n = code.size + 8;
    // whole device pixels per module, so no module blurs into another
    final unit = (size.shortestSide / n).floorToDouble().clamp(1.0, double.infinity);
    final side = unit * n;
    final origin = Offset((size.width - side) / 2, (size.height - side) / 2);
    canvas.drawRect(origin & Size(side, side), Paint()..color = light);
    final p = Paint()..color = dark;
    for (var r = 0; r < code.size; r++) {
      for (var c = 0; c < code.size; c++) {
        if (code.dark(r, c)) canvas.drawRect(origin + Offset((c + 4) * unit, (r + 4) * unit) & Size(unit, unit), p);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.code != code || old.dark != dark || old.light != light;
}
