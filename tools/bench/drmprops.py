#!/usr/bin/env python3
# Print a CRTC's and planes' KMS properties on the board, read-only
# (plan 0010: the dim plane's alpha; plan 0013: rotation).
#
#   drmprops.py CRTC_ID [PLANE_ID...]
#
# The DRM ioctls by hand, so it needs nothing but python3 on the image.
import array
import fcntl
import os
import struct
import sys

SET_CLIENT_CAP = 0x4010640D
OBJ_GETPROPERTIES = 0xC02064B9
GETPROPERTY = 0xC04064AA
OBJ_CRTC, OBJ_PLANE = 0xCCCCCCCC, 0xEEEEEEEE


def card():
    for n in sorted(os.listdir("/sys/class/drm")):
        if n.startswith("card") and "-" not in n and any(
                c.startswith(n + "-") for c in os.listdir("/sys/class/drm")):
            return os.open(f"/dev/dri/{n}", os.O_RDWR)
    raise SystemExit("drmprops: no DRM card with connectors")


def props(fd, obj, typ):
    b = bytearray(struct.pack("QQIII", 0, 0, 0, obj, typ) + b"\0" * 4)
    fcntl.ioctl(fd, OBJ_GETPROPERTIES, b)
    n = struct.unpack_from("QQIII", b)[2]
    ids = array.array("I", [0] * n)
    vals = array.array("Q", [0] * n)
    b = bytearray(struct.pack("QQIII", ids.buffer_info()[0], vals.buffer_info()[0], n, obj, typ) + b"\0" * 4)
    fcntl.ioctl(fd, OBJ_GETPROPERTIES, b)
    out = []
    for i, v in zip(ids, vals):
        pb = bytearray(struct.pack("QQII32sII", 0, 0, i, 0, b"", 0, 0))
        fcntl.ioctl(fd, GETPROPERTY, pb)
        out.append(f"{struct.unpack_from('QQII32s', pb)[4].split(b'\0')[0].decode()}={v}")
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: drmprops.py CRTC_ID [PLANE_ID...]")
    fd = card()
    fcntl.ioctl(fd, SET_CLIENT_CAP, struct.pack("QQ", 3, 1))  # atomic, implies universal planes
    print(f"crtc {sys.argv[1]}: {' '.join(props(fd, int(sys.argv[1]), OBJ_CRTC))}")
    for p in sys.argv[2:]:
        print(f"plane {p}: {' '.join(props(fd, int(p), OBJ_PLANE))}")
