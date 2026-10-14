#!/usr/bin/env python3
# Bench power meter: an FNIRSI FNB58 (or FNB48S) in line with the board's
# supply, its PC data port on the bench Mac (plan 0012 Part C).
#
#   power-meter.py log SECONDS CSV          one session, every sample to CSV
#   power-meter.py window CSV START END     mean V, A, W between two unix times
#   power-meter.py now [SECONDS]            print one line a second
#
# Needs hidapi (pip install hidapi; brew install hidapi). The protocol is
# baryluk's fnirsi-usb-power-data-logger, checked against live readings on
# firmware 0.68: 64-byte reports, type 0x04 carries four samples of
# volts and amps as little-endian /100000.
#
# Run ONE long session and measure time windows of its log. Opening and
# closing sessions in quick succession froze the meter (bench,
# 2026-10-14); retries here are few and slow, and the start sequence is
# OpenFNB58's: drain stale reports, three commands 50 ms apart, each write
# retried, a keep-alive every 0.9 s.
import sys
import time

VID = 0x2E3C
PIDS = (0x5558, 0x0049)


def packet(cmd, check):
    return bytes([0x00, 0xAA, cmd]) + bytes(61) + bytes([check])


def open_meter():
    import hid
    for info in hid.enumerate(VID, 0):
        if info["product_id"] in PIDS:
            d = hid.device()
            d.open_path(info["path"])
            return d, info
    raise SystemExit("power-meter: no FNIRSI meter on USB (its PC data port to the Mac, a data cable)")


def send(d, pkt):
    for _ in range(20):
        if d.write(pkt) > 0:
            return True
        time.sleep(0.15)
    return False


def start():
    d, info = open_meter()
    d.set_nonblocking(1)
    drained = 0
    while drained < 200 and d.read(64):
        drained += 1
    d.set_nonblocking(0)
    ok = send(d, packet(0x81, 0x8E)); time.sleep(0.05)
    ok = send(d, packet(0x82, 0x96)) and ok; time.sleep(0.05)
    ok = send(d, packet(0x82, 0x96)) and ok
    if not ok:
        print("power-meter: the meter refused the start sequence", file=sys.stderr)
    return d, info


def samples(seconds):
    """Yield (unix_time, volts, amps) for `seconds`."""
    d, info = start()
    print(f"power-meter: {info.get('product_string')} ({info['product_id']:#06x})", file=sys.stderr)
    t0 = time.monotonic()
    keep = t0
    errors = 0
    while time.monotonic() - t0 < seconds:
        try:
            data = d.read(64, 1000)
        except OSError:
            errors += 1
            if errors > 3:
                raise
            try:
                d.close()
            except Exception:
                pass
            time.sleep(2.0)
            d, info = start()
            continue
        now = time.monotonic()
        if now - keep > 0.9:
            send(d, packet(0x83, 0x9E))
            keep = now
        if not data or len(data) < 62 or data[1] != 0x04:
            continue
        t = time.time()
        for i in range(4):
            s = bytes(data[2 + 15 * i: 2 + 15 * (i + 1)])
            yield t, int.from_bytes(s[0:4], "little") / 100000, int.from_bytes(s[4:8], "little") / 100000
    d.close()


def cmd_log(seconds, path):
    with open(path, "w", buffering=1) as f:
        f.write("unix_time,volts,amps\n")
        for t, v, a in samples(seconds):
            f.write(f"{t:.3f},{v:.5f},{a:.5f}\n")


def cmd_window(path, a, b):
    v = c = w = n = 0
    for line in open(path):
        if line.startswith("unix"):
            continue
        t, volts, amps = map(float, line.split(","))
        if a <= t <= b:
            v += volts; c += amps; w += volts * amps; n += 1
    print(f"{w / n:.3f} W ({c / n:.4f} A at {v / n:.3f} V, {n} samples)" if n else "no samples")


def cmd_now(seconds):
    acc, sec = [], int(time.time())
    for t, v, a in samples(seconds):
        acc.append((v, a))
        if int(t) != sec:
            sec = int(t)
            mv = sum(x for x, _ in acc) / len(acc)
            ma = sum(y for _, y in acc) / len(acc)
            mw = sum(x * y for x, y in acc) / len(acc)
            print(f"{mv:6.3f} V  {ma:6.4f} A  {mw:6.3f} W  ({len(acc)} samples)", flush=True)
            acc = []


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["log"] and len(args) == 3:
        cmd_log(float(args[1]), args[2])
    elif args[:1] == ["window"] and len(args) == 4:
        cmd_window(args[1], float(args[2]), float(args[3]))
    elif args[:1] == ["now"]:
        cmd_now(float(args[1]) if len(args) > 1 else 10)
    else:
        sys.exit(__doc__ or "usage: power-meter.py log SECONDS CSV | window CSV START END | now [SECONDS]")
