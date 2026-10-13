#!/usr/bin/env python3
# Bench mouse and keyboard: uinput devices through the kernel's input
# stack, so libinput and the compositor see what a USB mouse and keyboard
# produce. Steps run in order:
#
#   hid.py point X Y        absolute pointer (a tablet-style mouse) to X,Y
#   hid.py move DX DY       relative motion, as a mouse sends it
#   hid.py click | right | back      press and release that button
#   hid.py wheel N          N wheel clicks (positive: down)
#   hid.py key NAME         press and release KEY_NAME (TAB, ENTER, ESC, DOWN...)
#   hid.py hold NAME SECS   hold KEY_NAME (to see it repeat)
#   hid.py type TEXT        lower-case letters, digits and spaces
#   hid.py wait SECS
#
# e.g.  hid.py point 240 320 wait 1 click key TAB key TAB key ENTER
import fcntl, os, struct, sys, time

W, H = 480, 640
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT, UI_SET_ABSBIT = 0x40045564, 0x40045565, 0x40045566, 0x40045567
UI_DEV_SETUP, UI_ABS_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY = 0x405C5503, 0x401C5504, 0x5501, 0x5502
EV_SYN, EV_KEY, EV_REL, EV_ABS = 0, 1, 2, 3
REL_X, REL_Y, REL_WHEEL, REL_WHEEL_HI_RES = 0, 1, 8, 11
ABS_X, ABS_Y = 0, 1
BTN = {"click": 0x110, "right": 0x111, "middle": 0x112, "back": 0x113}
KEYS = {
    "ESC": 1, "BACKSPACE": 14, "TAB": 15, "ENTER": 28, "SPACE": 57, "LEFTSHIFT": 42, "LEFTCTRL": 29,
    "UP": 103, "LEFT": 105, "RIGHT": 106, "DOWN": 108,
}
for i, c in enumerate("1234567890"):
    KEYS[c] = 2 + i
for row, start in (("qwertyuiop", 16), ("asdfghjkl", 30), ("zxcvbnm", 44)):
    for i, c in enumerate(row):
        KEYS[c.upper()] = start + i


def device(name, setup):
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    setup(fd)
    fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("<4H80sI", 0x03, 0x1, 0x2, 1, name, 0))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def mouse_setup(fd):
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
    for b in BTN.values():
        fcntl.ioctl(fd, UI_SET_KEYBIT, b)
    for r in (REL_X, REL_Y, REL_WHEEL, REL_WHEEL_HI_RES):
        fcntl.ioctl(fd, UI_SET_RELBIT, r)


def tablet_setup(fd):
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_ABS)
    for b in BTN.values():
        fcntl.ioctl(fd, UI_SET_KEYBIT, b)
    for code, top in ((ABS_X, W - 1), (ABS_Y, H - 1)):
        fcntl.ioctl(fd, UI_SET_ABSBIT, code)
        fcntl.ioctl(fd, UI_ABS_SETUP, struct.pack("<H2x6i", code, 0, 0, top, 0, 0, 0))


def keyboard_setup(fd):
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for k in KEYS.values():
        fcntl.ioctl(fd, UI_SET_KEYBIT, k)


mouse = device(b"vrx-bench-mouse", mouse_setup)
tablet = device(b"vrx-bench-tablet", tablet_setup)
keyboard = device(b"vrx-bench-keyboard", keyboard_setup)
time.sleep(1.5)  # let udev and libinput pick the devices up


def emit(fd, t, c, v):
    os.write(fd, struct.pack("<qqHHi", 0, 0, t, c, v))


def syn(fd):
    emit(fd, EV_SYN, 0, 0)


def press(fd, code):
    emit(fd, EV_KEY, code, 1)
    syn(fd)
    time.sleep(0.05)
    emit(fd, EV_KEY, code, 0)
    syn(fd)
    time.sleep(0.15)


args = sys.argv[1:]
last = tablet  # buttons go to the device that moved last
while args:
    op = args.pop(0)
    if op == "point":
        x, y = int(args.pop(0)), int(args.pop(0))
        emit(tablet, EV_ABS, ABS_X, x)
        emit(tablet, EV_ABS, ABS_Y, y)
        syn(tablet)
        time.sleep(0.2)
        last = tablet
    elif op == "move":
        dx, dy = int(args.pop(0)), int(args.pop(0))
        steps = max(abs(dx), abs(dy)) // 4 + 1
        for _ in range(steps):
            emit(mouse, EV_REL, REL_X, dx // steps)
            emit(mouse, EV_REL, REL_Y, dy // steps)
            syn(mouse)
            time.sleep(0.008)
        last = mouse
    elif op in BTN:
        press(last, BTN[op])
    elif op == "wheel":
        n = int(args.pop(0))
        for _ in range(abs(n)):
            emit(mouse, EV_REL, REL_WHEEL, -1 if n > 0 else 1)
            emit(mouse, EV_REL, REL_WHEEL_HI_RES, -120 if n > 0 else 120)
            syn(mouse)
            time.sleep(0.1)
    elif op == "key":
        press(keyboard, KEYS[args.pop(0).upper()])
    elif op == "hold":
        code, secs = KEYS[args.pop(0).upper()], float(args.pop(0))
        emit(keyboard, EV_KEY, code, 1)
        syn(keyboard)
        time.sleep(secs)
        emit(keyboard, EV_KEY, code, 0)
        syn(keyboard)
    elif op == "type":
        for c in args.pop(0):
            press(keyboard, KEYS["SPACE" if c == " " else c.upper()])
    elif op == "wait":
        time.sleep(float(args.pop(0)))
    else:
        sys.exit(f"hid.py: unknown step {op!r}")
time.sleep(0.5)
for fd in (mouse, tablet, keyboard):
    fcntl.ioctl(fd, UI_DEV_DESTROY)
