/// A pseudo-terminal running zsh, through libc over dart:ffi.
///
/// The applet never forks inside the Dart VM: it opens the master with
/// posix_openpt, then starts zsh as an ordinary child whose stdio is the
/// slave, made its controlling terminal by `setsid -c`. Reads block in a
/// second isolate (poll, then read) so the isolate that builds frames
/// never waits on the shell; writes are non-blocking and queue when the
/// pty is full.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// Linux generic (aarch64, x86_64) values
const _oRdwr = 0x2;
const _oNoctty = 0x100;
const _oNonblock = 0x800;
const _oCloexec = 0x80000;
const _tiocswinsz = 0x5414;
const _pollin = 0x1;
const _eintr = 4;
const _eagain = 11;

final _libc = DynamicLibrary.process();
final _posixOpenpt = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('posix_openpt');
final _grantpt = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('grantpt');
final _unlockpt = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('unlockpt');
final _ptsnameR = _libc
    .lookupFunction<Int32 Function(Int32, Pointer<Utf8>, Size), int Function(int, Pointer<Utf8>, int)>('ptsname_r');
final _open = _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>('open');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _write = _libc
    .lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, Size), int Function(int, Pointer<Uint8>, int)>('write');
final _ioctl = _libc.lookupFunction<Int32 Function(Int32, UnsignedLong, VarArgs<(Pointer<Uint16>,)>),
    int Function(int, int, Pointer<Uint16>)>('ioctl');
final _errno = _libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__errno_location');

/// One shell session. [output] carries what the shell writes and closes
/// when the session is over: when no process holds the slave any more,
/// which is also right when setsid had to fork.
class Pty {
  Pty._(this._master, this._slave, this._process) {
    // the reader sees EIO once no slave is open: ours goes when the
    // child does, by which time the shell holds its own
    unawaited(_process.exitCode.then((_) => _close(_slave)));
  }

  final int _master;
  final int _slave;
  final Process _process;
  final _out = StreamController<Uint8List>();
  final _pending = <int>[];
  Timer? _retry;

  Stream<Uint8List> get output => _out.stream;

  /// Open a pty and start [shell] on it, [columns] by [rows].
  static Future<Pty> start({
    String shell = '/bin/zsh',
    required int columns,
    required int rows,
    Map<String, String> environment = const {},
    String? workingDirectory,
  }) async {
    final master = _posixOpenpt(_oRdwr | _oNoctty | _oNonblock | _oCloexec);
    if (master < 0) throw OSError('posix_openpt', _errno().value);
    if (_grantpt(master) != 0 || _unlockpt(master) != 0) {
      final err = _errno().value;
      _close(master);
      throw OSError('grantpt/unlockpt', err);
    }
    final name = calloc<Uint8>(64).cast<Utf8>();
    final String slavePath;
    try {
      if (_ptsnameR(master, name, 64) != 0) throw OSError('ptsname_r', _errno().value);
      slavePath = name.toDartString();
    } finally {
      calloc.free(name);
    }
    // our own slave descriptor keeps the master readable (no HUP) until
    // the shell has opened the slave itself
    final path = slavePath.toNativeUtf8();
    final slave = _open(path, _oRdwr | _oNoctty | _oCloexec);
    calloc.free(path);
    if (slave < 0) {
      final err = _errno().value;
      _close(master);
      throw OSError('open $slavePath', err);
    }
    _resize(master, columns, rows);
    // sh is zsh too; it only redirects stdio onto the slave and becomes,
    // through setsid -c, the session leader the slave controls
    final process = await Process.start(
      '/bin/sh',
      ['-c', r'exec setsid -c "$2" -l <"$1" >"$1" 2>&1', 'sh', slavePath, shell],
      environment: {'TERM': 'xterm-256color', 'COLORTERM': 'truecolor', 'LANG': 'C.UTF-8', ...environment},
      workingDirectory: workingDirectory,
    );
    // sh's own pipes carry nothing once stdio is redirected
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    unawaited(process.stdin.close());
    final pty = Pty._(master, slave, process);
    await pty._startReader();
    return pty;
  }

  Future<void> _startReader() async {
    final port = ReceivePort();
    await Isolate.spawn(_readLoop, (_master, port.sendPort));
    port.listen((message) {
      if (message is TransferableTypedData) {
        _out.add(message.materialize().asUint8List());
      } else {
        port.close();
        _close(_master);
        unawaited(_out.close());
      }
    });
  }

  /// Send keystrokes or a paste to the shell.
  void write(List<int> bytes) {
    _pending.addAll(bytes);
    _flush();
  }

  void _flush() {
    _retry?.cancel();
    if (_pending.isEmpty) return;
    final buf = calloc<Uint8>(_pending.length);
    try {
      buf.asTypedList(_pending.length).setAll(0, _pending);
      final n = _write(_master, buf, _pending.length);
      if (n > 0) {
        _pending.removeRange(0, n);
      } else if (n < 0 && _errno().value != _eagain && _errno().value != _eintr) {
        _pending.clear(); // the shell is gone
        return;
      }
    } finally {
      calloc.free(buf);
    }
    // the pty's buffer is full: the shell has not read yet
    // poll-ok: only while the shell has unread input queued; it stops once the buffer drains
    if (_pending.isNotEmpty) _retry = Timer(const Duration(milliseconds: 10), _flush);
  }

  /// Tell the shell its new size (it gets SIGWINCH).
  void resize(int columns, int rows) => _resize(_master, columns, rows);

  static void _resize(int fd, int columns, int rows) {
    final ws = calloc<Uint16>(4);
    ws[0] = rows;
    ws[1] = columns;
    _ioctl(fd, _tiocswinsz, ws);
    calloc.free(ws);
  }

  /// End the session: SIGHUP, as a closed terminal does.
  void kill() => _process.kill(ProcessSignal.sighup);
}

/// The reader isolate: poll the master, read what is there, send it on;
/// a null message means the session ended (EIO: no slave open).
void _readLoop((int, SendPort) args) {
  final (fd, port) = args;
  final lib = DynamicLibrary.process();
  final poll = lib.lookupFunction<Int32 Function(Pointer<Int32>, Uint64, Int32), int Function(Pointer<Int32>, int, int)>(
      'poll');
  final read = lib
      .lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, Size), int Function(int, Pointer<Uint8>, int)>('read');
  final errno = lib.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__errno_location');
  // struct pollfd { int fd; short events; short revents; }
  final pfd = calloc<Int32>(2);
  const size = 16384;
  final buf = calloc<Uint8>(size);
  while (true) {
    pfd[0] = fd;
    pfd[1] = _pollin;
    if (poll(pfd, 1, -1) < 0) {
      if (errno().value == _eintr) continue;
      break;
    }
    final n = read(fd, buf, size);
    if (n > 0) {
      port.send(TransferableTypedData.fromList([Uint8List.fromList(buf.asTypedList(n))]));
    } else if (n < 0 && (errno().value == _eagain || errno().value == _eintr)) {
      continue;
    } else {
      break;
    }
  }
  calloc.free(pfd);
  calloc.free(buf);
  port.send(null);
}
