# A script with its own screen (the vrx module, plan 0013 D13): a row
# to press, a row to reset, and how many presses so far.
import vrx

count = 0
while True:
    vrx.screen("Counter", [
        vrx.text(f"Pressed {count} times."),
        vrx.row("Press", tap="press"),
        vrx.row("Reset", tap="reset"),
    ])
    tap = next(vrx.taps(), None)
    if tap is None:
        break
    count = 0 if tap == "reset" else count + 1
