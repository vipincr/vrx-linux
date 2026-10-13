#!/usr/bin/env python3
# Read back the CRTC's current scanout buffer (root: GETFB2 needs
# CAP_SYS_ADMIN) and write it as a PNG. Diagnostic for the bench.
import fcntl, mmap, os, struct, sys, zlib
def IOWR(nr, size): return (3 << 30) | (size << 16) | (0x64 << 8) | nr
crtc_id = int(sys.argv[1]); out = sys.argv[2]
# the display card: whichever answers GETCRTC (card numbers follow probe
# order and swap between boots)
import glob
for node in sorted(glob.glob("/dev/dri/card*")):
    fd = os.open(node, os.O_RDWR)
    crtc = bytearray(104); struct.pack_into("=I", crtc, 12, crtc_id)
    try:
        fcntl.ioctl(fd, IOWR(0xA1, 104), crtc)
        break
    except OSError:
        os.close(fd)
else:
    sys.exit("no DRM card answers for crtc %d" % crtc_id)
fb_id = struct.unpack_from("=I", crtc, 16)[0]
fb = bytearray(104); struct.pack_into("=I", fb, 0, fb_id)
fcntl.ioctl(fd, IOWR(0xCE, 104), fb)
_, w, h, fmt, flags = struct.unpack_from("=5I", fb, 0)
handle = struct.unpack_from("=I", fb, 20)[0]; pitch = struct.unpack_from("=I", fb, 36)[0]
prime = bytearray(struct.pack("=IIi", handle, 0x80000 | 2, -1))
fcntl.ioctl(fd, IOWR(0x2D, 12), prime)
dfd = struct.unpack_from("=i", prime, 8)[0]
m = mmap.mmap(dfd, pitch * h, mmap.MAP_SHARED, mmap.PROT_READ)
raw = bytearray()
for y in range(h):
    row = m[y * pitch:y * pitch + w * 4]
    raw.append(0)
    for x in range(0, w * 4, 4):  # XRGB/ARGB8888 little-endian: B G R A
        raw += bytes((row[x + 2], row[x + 1], row[x]))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b"")
open(out, "wb").write(png)
print(f"fb {fb_id} {w}x{h} pitch {pitch} format {fmt:#x} -> {out}")
