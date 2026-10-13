# A vrx script: anything print()ed shows in the console.
import platform, time

print("Hello from", platform.node())
for i in range(5):
    print("tick", i + 1)
    time.sleep(0.5)
print("done")
