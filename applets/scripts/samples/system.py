# What the device is running, from the files Linux keeps.
def first(path, prefix=""):
    try:
        with open(path) as f:
            for line in f:
                if line.startswith(prefix):
                    return line.strip()
    except OSError as e:
        return f"{path}: {e.strerror}"
    return ""

print(first("/etc/os-release", "PRETTY_NAME"))
print(first("/proc/device-tree/model").rstrip("\x00"))
print(first("/proc/meminfo", "MemTotal"))
print(first("/proc/meminfo", "SwapTotal"))
with open("/proc/loadavg") as f:
    print("load", f.read().split()[:3])
