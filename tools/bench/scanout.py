#!/usr/bin/env python3
# What the panel shows, as a PNG (root: GETFB2 needs CAP_SYS_ADMIN):
#
#   scanout.py OUT.png [CRTC]
#
# The CRTC's primary framebuffer with every overlay plane bound to that
# CRTC blended over it, premultiplied, in plane order (the shell's strip
# is one, plan 0008 D10). Overlays are taken as full-screen at 0,0, which
# is where the compositor puts the shell (GETPLANE reports no position);
# a plane of another size (the cursor) is left out. Without CRTC: the
# first CRTC with a framebuffer, on whichever card has one (card numbers
# follow probe order and swap between boots).
import ctypes, fcntl, glob, mmap, os, struct, sys, zlib


def IOWR(nr, size):
    return (3 << 30) | (size << 16) | (0x64 << 8) | nr


GETRESOURCES, GETCRTC = IOWR(0xA0, 64), IOWR(0xA1, 104)
GETPLANERESOURCES, GETPLANE = IOWR(0xB5, 16), IOWR(0xB6, 32)
GETFB2, PRIME_HANDLE_TO_FD = IOWR(0xCE, 104), IOWR(0x2D, 12)


def address(buf):
    return ctypes.addressof((ctypes.c_char * len(buf)).from_buffer(buf))


def crtcs(fd):
    # struct drm_mode_card_res: four u64 array pointers (fbs, crtcs,
    # connectors, encoders), then their four u32 counts at 32
    res = bytearray(64)
    fcntl.ioctl(fd, GETRESOURCES, res)
    n = struct.unpack_from("=I", res, 36)[0]
    arr = bytearray(4 * max(n, 1))
    res = bytearray(64)
    struct.pack_into("=Q", res, 8, address(arr))
    struct.pack_into("=I", res, 36, n)
    fcntl.ioctl(fd, GETRESOURCES, res)
    return list(struct.unpack_from("=%dI" % n, arr))


def planes(fd):
    # struct drm_mode_get_plane_res {u64 plane_id_ptr; u32 count_planes}
    res = bytearray(16)
    fcntl.ioctl(fd, GETPLANERESOURCES, res)
    n = struct.unpack_from("=I", res, 8)[0]
    arr = bytearray(4 * max(n, 1))
    struct.pack_into("=Q", res, 0, address(arr))
    fcntl.ioctl(fd, GETPLANERESOURCES, res)
    return list(struct.unpack_from("=%dI" % n, arr))


def crtc_fb(fd, crtc_id):
    crtc = bytearray(104)
    struct.pack_into("=I", crtc, 12, crtc_id)
    fcntl.ioctl(fd, GETCRTC, crtc)
    return struct.unpack_from("=I", crtc, 16)[0]


def read_fb(fd, fb_id):
    """(width, height, rows of B G R A, tight)."""
    fb = bytearray(104)
    struct.pack_into("=I", fb, 0, fb_id)
    fcntl.ioctl(fd, GETFB2, fb)
    w, h = struct.unpack_from("=2I", fb, 4)
    handle, pitch = struct.unpack_from("=I", fb, 20)[0], struct.unpack_from("=I", fb, 36)[0]
    prime = bytearray(struct.pack("=IIi", handle, 0x80000 | 2, -1))
    fcntl.ioctl(fd, PRIME_HANDLE_TO_FD, prime)
    dfd = struct.unpack_from("=i", prime, 8)[0]
    m = mmap.mmap(dfd, pitch * h, mmap.MAP_SHARED, mmap.PROT_READ)
    px = bytearray()
    for y in range(h):
        px += m[y * pitch:y * pitch + w * 4]
    m.close()
    os.close(dfd)
    return w, h, px


out = sys.argv[1]
want = int(sys.argv[2]) if len(sys.argv) > 2 else None
fd = crtc_id = None
for node in sorted(glob.glob("/dev/dri/card*")):
    fd = os.open(node, os.O_RDWR)
    try:
        crtc_id = next((c for c in ([want] if want else crtcs(fd)) if crtc_fb(fd, c)), None)
    except OSError:
        crtc_id = None
    if crtc_id is not None:
        break
    os.close(fd)
if crtc_id is None:
    sys.exit("no DRM card has a lit CRTC")

primary = crtc_fb(fd, crtc_id)
w, h, base = read_fb(fd, primary)
layers = 0
for p in sorted(planes(fd)):
    # struct drm_mode_get_plane {plane_id, crtc_id, fb_id, ...}
    gp = bytearray(32)
    struct.pack_into("=I", gp, 0, p)
    fcntl.ioctl(fd, GETPLANE, gp)
    _, pcrtc, pfb = struct.unpack_from("=3I", gp, 0)
    if pcrtc != crtc_id or not pfb or pfb == primary:
        continue
    lw, lh, px = read_fb(fd, pfb)
    if (lw, lh) != (w, h):
        continue
    layers += 1
    for i in range(0, w * h * 4, 4):
        a = px[i + 3]
        if a:
            k = 255 - a
            base[i] = min(255, px[i] + base[i] * k // 255)
            base[i + 1] = min(255, px[i + 1] + base[i + 1] * k // 255)
            base[i + 2] = min(255, px[i + 2] + base[i + 2] * k // 255)

raw = bytearray()
for y in range(h):
    raw.append(0)
    row = base[y * w * 4:(y + 1) * w * 4]
    for x in range(0, w * 4, 4):
        raw += bytes((row[x + 2], row[x + 1], row[x]))


def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b"")
open(out, "wb").write(png)
print(f"crtc {crtc_id} {w}x{h}, {layers} overlay(s) -> {out}")
