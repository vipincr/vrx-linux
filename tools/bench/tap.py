#!/usr/bin/env python3
# Bench touch injector: a uinput multitouch screen the size of the panel.
#   tap.py X Y [count] [interval_s]
#   tap.py swipe X1 Y1 X2 Y2 [ms]    one finger dragged X1,Y1 to X2,Y2
# Each tap is a down, 60 ms held, up, through the kernel's input stack,
# so libinput and the compositor see exactly what a finger produces.
import fcntl, os, struct, sys, time

W, H = 480, 640
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT, UI_SET_PROPBIT = 0x40045564, 0x40045565, 0x40045567, 0x4004556E
UI_DEV_SETUP, UI_ABS_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY = 0x405C5503, 0x401C5504, 0x5501, 0x5502
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
BTN_TOUCH = 0x14A
ABS_X, ABS_Y, ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0, 1, 0x2F, 0x35, 0x36, 0x39
INPUT_PROP_DIRECT = 1

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_ABS)
fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH)
fcntl.ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT)
for code, top in [(ABS_X, W - 1), (ABS_Y, H - 1), (ABS_MT_SLOT, 0), (ABS_MT_POSITION_X, W - 1),
                  (ABS_MT_POSITION_Y, H - 1), (ABS_MT_TRACKING_ID, 65535)]:
    fcntl.ioctl(fd, UI_SET_ABSBIT, code)
    # struct uinput_abs_setup { u16 code; struct input_absinfo {s32 value,min,max,fuzz,flat,res} }
    fcntl.ioctl(fd, UI_ABS_SETUP, struct.pack("<H2x6i", code, 0, 0, top, 0, 0, 0))
# struct uinput_setup { struct input_id {u16 bustype,vendor,product,version}; char name[80]; u32 ff }
fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("<4H80sI", 0x06, 0x1, 0x1, 1, b"vrx-bench-touch", 0))
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1.5)  # let udev and libinput pick the device up

def emit(t, c, v):
    os.write(fd, struct.pack("<qqHHi", 0, 0, t, c, v))

def put(x, y):
    emit(EV_ABS, ABS_MT_POSITION_X, x)
    emit(EV_ABS, ABS_MT_POSITION_Y, y)
    emit(EV_ABS, ABS_X, x)
    emit(EV_ABS, ABS_Y, y)

if sys.argv[1] == "swipe":
    x1, y1, x2, y2 = (int(v) for v in sys.argv[2:6])
    ms = int(sys.argv[6]) if len(sys.argv) > 6 else 200
    steps = max(ms // 10, 2)
    emit(EV_ABS, ABS_MT_SLOT, 0)
    emit(EV_ABS, ABS_MT_TRACKING_ID, 1)
    put(x1, y1)
    emit(EV_KEY, BTN_TOUCH, 1)
    emit(EV_SYN, 0, 0)
    for i in range(1, steps + 1):
        time.sleep(ms / 1000 / steps)
        put(x1 + (x2 - x1) * i // steps, y1 + (y2 - y1) * i // steps)
        emit(EV_SYN, 0, 0)
    emit(EV_ABS, ABS_MT_TRACKING_ID, -1)
    emit(EV_KEY, BTN_TOUCH, 0)
    emit(EV_SYN, 0, 0)
    time.sleep(0.5)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    sys.exit(0)

x, y = int(sys.argv[1]), int(sys.argv[2])
count = int(sys.argv[3]) if len(sys.argv) > 3 else 1
interval = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
for i in range(count):
    emit(EV_ABS, ABS_MT_SLOT, 0)
    emit(EV_ABS, ABS_MT_TRACKING_ID, i + 1)
    emit(EV_ABS, ABS_MT_POSITION_X, x)
    emit(EV_ABS, ABS_MT_POSITION_Y, y)
    emit(EV_KEY, BTN_TOUCH, 1)
    emit(EV_ABS, ABS_X, x)
    emit(EV_ABS, ABS_Y, y)
    emit(EV_SYN, 0, 0)
    time.sleep(0.06)
    emit(EV_ABS, ABS_MT_TRACKING_ID, -1)
    emit(EV_KEY, BTN_TOUCH, 0)
    emit(EV_SYN, 0, 0)
    time.sleep(interval)
time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)
