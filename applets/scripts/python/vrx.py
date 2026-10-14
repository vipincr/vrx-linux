"""vrx: a script's own screen on the Scripts applet (vrx plan 0013 D13).

A script draws by printing one JSON line on standard output, and hears
taps as lines on standard input; the Scripts applet renders the screen
with its own rows and writes {"tap": "<id>"} when one is pressed. No other
channel exists: a script run from a terminal shows the JSON and reads
taps typed by hand.

    import vrx
    count = 0
    while True:
        vrx.screen("Counter", [vrx.text(f"Pressed {count} times"),
                               vrx.row("Press", tap="press")])
        for tap in vrx.taps():
            count += 1
            break

A screen holds at most ROWS rows; Back on the applet stops the script.
"""

import json
import sys

ROWS = 50


def row(label, value=None, tap=None):
    """A row: a label, an optional value on its right, and the tap id it
    sends when pressed (no id: the row is a status line)."""
    item = {"row": str(label)}
    if value is not None:
        item["value"] = str(value)
    if tap is not None:
        item["tap"] = str(tap)
    return item


def text(paragraph):
    """A paragraph of text, wrapped to the screen."""
    return {"text": str(paragraph)}


def screen(title, items):
    """Show a screen titled `title` holding `items` (rows and text)."""
    items = list(items)[:ROWS]
    print(json.dumps({"screen": items, "title": str(title)}), flush=True)


def clear():
    """Back to the console: the script's output, as printed."""
    print(json.dumps({"screen": None}), flush=True)


def events():
    """Every input line, as ("tap", id) for a pressed row or ("line", text)
    for a line typed on the applet's keyboard."""
    for raw in sys.stdin:
        line = raw.rstrip("\n")
        try:
            message = json.loads(line)
        except ValueError:
            message = None
        if isinstance(message, dict) and isinstance(message.get("tap"), str):
            yield ("tap", message["tap"])
        else:
            yield ("line", line)


def taps():
    """The ids of pressed rows, in order; typed lines are skipped."""
    for kind, value in events():
        if kind == "tap":
            yield value
