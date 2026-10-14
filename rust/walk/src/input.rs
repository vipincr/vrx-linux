// The walk's finger and keyboard: uinput devices, so libinput and the
// compositor see what a touchscreen and a USB keyboard produce. The
// shapes and timings are tools/bench/tap.py's and hid.py's, which drove
// the CM4 bench: a tap is down, 60 ms, up; a key is down, 50 ms, up.

// The encodings are used by the Linux device code only; a host build
// (tests) keeps them for the checks against the bench's numbers.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use std::time::Duration;

/// `_IOW('U', nr, size)` and `_IO('U', nr)` in the asm-generic encoding
/// arm64 and x86-64 share (asm-generic/ioctl.h): direction in bits 30-31,
/// size in 16-29, type in 8-15, number in 0-7.
pub const fn iow(nr: u64, size: u64) -> u64 {
    (1 << 30) | (size << 16) | (0x55 << 8) | nr
}
pub const fn io(nr: u64) -> u64 {
    (0x55 << 8) | nr
}

pub const UI_DEV_CREATE: u64 = io(1);
pub const UI_DEV_DESTROY: u64 = io(2);
/// struct uinput_setup: input_id (4 x u16), name[80], ff_effects_max u32.
pub const UI_DEV_SETUP: u64 = iow(3, 92);
/// struct uinput_abs_setup: u16 code, 2 pad, input_absinfo (6 x s32).
pub const UI_ABS_SETUP: u64 = iow(4, 28);
pub const UI_SET_EVBIT: u64 = iow(100, 4);
pub const UI_SET_KEYBIT: u64 = iow(101, 4);
pub const UI_SET_ABSBIT: u64 = iow(103, 4);
pub const UI_SET_PROPBIT: u64 = iow(110, 4);

pub const EV_SYN: u16 = 0;
pub const EV_KEY: u16 = 1;
pub const EV_ABS: u16 = 3;
pub const BTN_TOUCH: u16 = 0x14A;
pub const ABS_X: u16 = 0;
pub const ABS_Y: u16 = 1;
pub const ABS_MT_SLOT: u16 = 0x2F;
pub const ABS_MT_POSITION_X: u16 = 0x35;
pub const ABS_MT_POSITION_Y: u16 = 0x36;
pub const ABS_MT_TRACKING_ID: u16 = 0x39;
pub const INPUT_PROP_DIRECT: u16 = 1;

/// struct input_event on a 64-bit kernel: timeval (two i64, left 0 for
/// the kernel to stamp), u16 type, u16 code, i32 value.
pub fn event(kind: u16, code: u16, value: i32) -> [u8; 24] {
    let mut e = [0u8; 24];
    e[16..18].copy_from_slice(&kind.to_ne_bytes());
    e[18..20].copy_from_slice(&code.to_ne_bytes());
    e[20..24].copy_from_slice(&value.to_ne_bytes());
    e
}

/// struct uinput_setup for a device called `name`.
pub fn setup(bus: u16, product: u16, name: &str) -> [u8; 92] {
    let mut s = [0u8; 92];
    for (i, v) in [bus, 1, product, 1].iter().enumerate() {
        s[i * 2..i * 2 + 2].copy_from_slice(&v.to_ne_bytes());
    }
    let n = name.as_bytes();
    s[8..8 + n.len().min(79)].copy_from_slice(&n[..n.len().min(79)]);
    s
}

/// struct uinput_abs_setup: an axis from 0 to `max`.
pub fn abs_setup(code: u16, max: i32) -> [u8; 28] {
    let mut s = [0u8; 28];
    s[0..2].copy_from_slice(&code.to_ne_bytes());
    s[12..16].copy_from_slice(&max.to_ne_bytes());
    s
}

#[cfg(target_os = "linux")]
mod dev {
    use std::fs::File;
    use std::io::Write;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    use super::*;

    pub struct Device {
        file: File,
    }

    impl Device {
        fn open() -> std::io::Result<Self> {
            let file = std::fs::OpenOptions::new()
                .write(true)
                .custom_flags(libc::O_NONBLOCK)
                .open("/dev/uinput")?;
            Ok(Self { file })
        }

        /// An ioctl taking an int.
        fn set(&self, request: u64, value: u16) -> std::io::Result<()> {
            // SAFETY: a uinput request whose argument is an int passed by
            // value; the descriptor is ours and open for the whole call.
            #[allow(unsafe_code)]
            let rc = unsafe {
                libc::ioctl(
                    self.file.as_raw_fd(),
                    request as _,
                    libc::c_int::from(value),
                )
            };
            if rc < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        }

        /// An ioctl taking a pointer to `arg`.
        fn put(&self, request: u64, arg: &[u8]) -> std::io::Result<()> {
            // SAFETY: the request's size (encoded in it, see iow) is
            // arg's length, so the kernel reads only within the slice,
            // which outlives the call.
            #[allow(unsafe_code)]
            let rc =
                unsafe { libc::ioctl(self.file.as_raw_fd(), request as _, arg.as_ptr()) };
            if rc < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        }

        fn create(&self) -> std::io::Result<()> {
            // SAFETY: UI_DEV_CREATE takes no argument.
            #[allow(unsafe_code)]
            let rc = unsafe { libc::ioctl(self.file.as_raw_fd(), UI_DEV_CREATE as _) };
            if rc < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        }

        pub fn emit(&mut self, kind: u16, code: u16, value: i32) -> std::io::Result<()> {
            self.file.write_all(&event(kind, code, value))
        }

        pub fn touch(width: u32, height: u32) -> std::io::Result<Self> {
            let d = Self::open()?;
            d.set(UI_SET_EVBIT, EV_KEY)?;
            d.set(UI_SET_EVBIT, EV_ABS)?;
            d.set(UI_SET_KEYBIT, BTN_TOUCH)?;
            d.set(UI_SET_PROPBIT, INPUT_PROP_DIRECT)?;
            let (w, h) = (
                width.saturating_sub(1) as i32,
                height.saturating_sub(1) as i32,
            );
            for (code, max) in [
                (ABS_X, w),
                (ABS_Y, h),
                (ABS_MT_SLOT, 0),
                (ABS_MT_POSITION_X, w),
                (ABS_MT_POSITION_Y, h),
                (ABS_MT_TRACKING_ID, 65535),
            ] {
                d.set(UI_SET_ABSBIT, code)?;
                d.put(UI_ABS_SETUP, &abs_setup(code, max))?;
            }
            d.put(UI_DEV_SETUP, &setup(0x06, 0x10, "vrx-walk-touch"))?;
            d.create()?;
            Ok(d)
        }

        pub fn keyboard() -> std::io::Result<Self> {
            let d = Self::open()?;
            d.set(UI_SET_EVBIT, EV_KEY)?;
            for code in 1..=127u16 {
                d.set(UI_SET_KEYBIT, code)?;
            }
            d.put(UI_DEV_SETUP, &setup(0x03, 0x11, "vrx-walk-keyboard"))?;
            d.create()?;
            Ok(d)
        }
    }

    impl Drop for Device {
        fn drop(&mut self) {
            // SAFETY: UI_DEV_DESTROY takes no argument.
            #[allow(unsafe_code)]
            unsafe {
                libc::ioctl(self.file.as_raw_fd(), UI_DEV_DESTROY as _);
            }
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod dev {
    pub struct Device;

    fn unsupported() -> std::io::Error {
        std::io::Error::new(std::io::ErrorKind::Unsupported, "uinput is Linux's")
    }

    impl Device {
        pub fn touch(_w: u32, _h: u32) -> std::io::Result<Self> {
            Err(unsupported())
        }
        pub fn keyboard() -> std::io::Result<Self> {
            Err(unsupported())
        }
        pub fn emit(&mut self, _k: u16, _c: u16, _v: i32) -> std::io::Result<()> {
            Err(unsupported())
        }
    }
}

/// A finger and a keyboard.
pub struct Hands {
    touch: dev::Device,
    keys: dev::Device,
    finger: i32,
}

impl Hands {
    pub fn new(width: u32, height: u32) -> std::io::Result<Self> {
        let hands = Self {
            touch: dev::Device::touch(width, height)?,
            keys: dev::Device::keyboard()?,
            finger: 0,
        };
        // let udev and libinput take the devices up (tap.py's 1.5 s)
        std::thread::sleep(Duration::from_millis(1500));
        Ok(hands)
    }

    fn at(&mut self, x: u32, y: u32) -> std::io::Result<()> {
        let (x, y) = (x as i32, y as i32);
        self.touch.emit(EV_ABS, ABS_MT_POSITION_X, x)?;
        self.touch.emit(EV_ABS, ABS_MT_POSITION_Y, y)?;
        self.touch.emit(EV_ABS, ABS_X, x)?;
        self.touch.emit(EV_ABS, ABS_Y, y)
    }

    fn down(&mut self, x: u32, y: u32) -> std::io::Result<()> {
        self.finger = self.finger % 65000 + 1;
        self.touch.emit(EV_ABS, ABS_MT_SLOT, 0)?;
        self.touch.emit(EV_ABS, ABS_MT_TRACKING_ID, self.finger)?;
        self.at(x, y)?;
        self.touch.emit(EV_KEY, BTN_TOUCH, 1)?;
        self.touch.emit(EV_SYN, 0, 0)
    }

    fn up(&mut self) -> std::io::Result<()> {
        self.touch.emit(EV_ABS, ABS_MT_TRACKING_ID, -1)?;
        self.touch.emit(EV_KEY, BTN_TOUCH, 0)?;
        self.touch.emit(EV_SYN, 0, 0)
    }

    /// Touch for `ms` (a tap is 60).
    pub fn press(&mut self, (x, y): (u32, u32), ms: u32) -> std::io::Result<()> {
        self.down(x, y)?;
        std::thread::sleep(Duration::from_millis(u64::from(ms)));
        self.up()
    }

    /// Drag, a move every 10 ms.
    pub fn swipe(
        &mut self,
        from: (u32, u32),
        to: (u32, u32),
        ms: u32,
    ) -> std::io::Result<()> {
        let steps = (ms / 10).max(2);
        self.down(from.0, from.1)?;
        for i in 1..=steps {
            std::thread::sleep(Duration::from_millis(u64::from(ms / steps)));
            let lerp = |a: u32, b: u32| {
                (i64::from(a)
                    + (i64::from(b) - i64::from(a)) * i64::from(i) / i64::from(steps))
                    as u32
            };
            self.at(lerp(from.0, to.0), lerp(from.1, to.1))?;
            self.touch.emit(EV_SYN, 0, 0)?;
        }
        self.up()
    }

    pub fn key(&mut self, code: u16) -> std::io::Result<()> {
        self.keys.emit(EV_KEY, code, 1)?;
        self.keys.emit(EV_SYN, 0, 0)?;
        std::thread::sleep(Duration::from_millis(50));
        self.keys.emit(EV_KEY, code, 0)?;
        self.keys.emit(EV_SYN, 0, 0)?;
        std::thread::sleep(Duration::from_millis(150));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The numbers tap.py drove the bench with.
    #[test]
    fn the_requests_are_the_ones_the_bench_proved() {
        assert_eq!(UI_SET_EVBIT, 0x4004_5564);
        assert_eq!(UI_SET_KEYBIT, 0x4004_5565);
        assert_eq!(UI_SET_ABSBIT, 0x4004_5567);
        assert_eq!(UI_SET_PROPBIT, 0x4004_556E);
        assert_eq!(UI_DEV_SETUP, 0x405C_5503);
        assert_eq!(UI_ABS_SETUP, 0x401C_5504);
        assert_eq!(UI_DEV_CREATE, 0x5501);
        assert_eq!(UI_DEV_DESTROY, 0x5502);
    }

    #[test]
    fn the_structs_are_laid_out_as_the_kernel_reads_them() {
        let e = event(EV_ABS, ABS_MT_POSITION_X, 240);
        assert_eq!(&e[..16], &[0u8; 16], "the kernel stamps the time");
        assert_eq!(e[16..18], 3u16.to_ne_bytes());
        assert_eq!(e[20..24], 240i32.to_ne_bytes());
        let s = setup(0x06, 0x10, "vrx-walk-touch");
        assert_eq!(&s[8..22], b"vrx-walk-touch");
        assert_eq!(s[22], 0);
        let a = abs_setup(ABS_Y, 639);
        assert_eq!(
            a[12..16],
            639i32.to_ne_bytes(),
            "max follows code, pad and value"
        );
    }
}
