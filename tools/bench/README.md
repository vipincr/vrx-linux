# bench/

The checks of the applet OS, run against a board (review 2026-10-17,
ORG-01: this is the one home for them; board access — flash, console,
the bench network — is the vrx repo's `scripts/board/`, and its README
says the same split from its side).

## The shared harness

`lib.sh` (workstation side) and `lib-remote.sh` (board side) are the one
harness (KRN-04): the `ok`/`bad` rows, the one Varlink caller, the
verdict counted from what the board printed, and the dated record. A
check is:

```sh
HOST=${1:?usage: <check>.sh <board-host>}
. "$(dirname "$0")/ssh-env.sh"; O="$OPTS"
. "$(dirname "$0")/lib.sh"

run_check <<'EOF'
# the check's body, on the board: ok/bad/varlink are lib-remote's
summary
exit $fails
EOF
finish
```

`finish` writes `tests/bench/<board>/<date>.json` — board, image
version, every check that ran that day, its verdicts (Step 40). That
record is what CLAUDE.md's "state what you verified" points at: a board
half whose record predates its last change reads as unverified.

A check whose verdicts are decided on the workstation (the power
capture, shots) may use the local `ok`/`bad` and still `finish`.

## Rules the checks hold

- **Absence is never a pass** (CON-08): a row whose probe failed fails.
  `run_check` counts the board's exit status, and a body that finds
  nothing to check says so with `bad`, not with silence (freeze-check's
  "no vrx-applet@ units are active" row is the shape).
- **A mutating check restores on every exit** (CON-10): the backup lives
  outside the overwritten path, and the `trap` that restores it is
  installed the moment the backup is taken (power-check's screen.conf).
- **The destructive sequence waits for its instrument** (CON-10):
  power-check refuses to start its states until the meter's log has
  rows.
- **A reader refuses what it cannot decode** (CON-05): scanout.py names
  the fb's format and modifier and exits on anything but linear
  32-bit ARGB/XRGB.

## Not yet on the harness

bridge-check, camera-check, install's local prep aside, matter-check,
ml-check, partb-check, update-check and usb-hotplug-qemu still carry
their own copies of the rows and the caller; folding each into
`run_check` is mechanical and one check at a time. Their copies are the
open remainder of review step 39.
