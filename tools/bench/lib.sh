#!/bin/sh
# bench/lib.sh: the one harness every bench check shares (review
# 2026-10-17, KRN-04): it ships the board-side half (lib-remote.sh: the
# ok/bad rows, the one Varlink caller) beside the check's body, counts
# the verdicts from what the board printed, and writes the dated record
# (Step 40). A check sources ssh-env.sh then this:
#
#   . "$(dirname "$0")/lib.sh"
#   run_check <<'EOF'
#   ...the check's body, on the board: ok/bad/varlink...
#   exit $fails
#   EOF
#   finish
#
# The record (CLAUDE.md's "state what you verified", as a file): every
# check that runs through finish() writes
# tests/bench/<board>/<date>.json — board, image version, the check, the
# verdicts — so a board half whose record is older than its last change
# reads as unverified, not as done.

NAME=$(basename "$0" .sh)

# Local rows (a check whose verdicts are decided on the workstation).
fails=0
oks=0
ok()  { oks=$((oks + 1)); echo "  ok    $*"; }
bad() { fails=$((fails + 1)); echo "  FAIL  $*"; }

# Ship the harness and the body to the board and run them; the verdicts
# are counted from the printed rows, so a row no probe could reach fails
# by being absent from the count only when its probe's error was said
# (CON-08: absence never reads as a pass).
run_check() {
    # REMOTE_ENV, when set, reaches the board's body (a check that needs
    # a value from its local prep: install-check's certificate CN)
    # shellcheck disable=SC2086
    out=$({ cat "$(dirname "$0")/lib-remote.sh"; cat; } \
          | ssh $O "root@$HOST" "env ${REMOTE_ENV:-} sh -s /tmp/vrx-bench-$NAME")
    status=$?
    printf '%s\n' "$out"
    if [ "$status" != 0 ]; then
        echo "  FAIL  the board run exited $status (ssh or probe failed)"
    fi
    fails=$(printf '%s\n' "$out" | grep -c '^  FAIL' || true)
    oks=$(printf '%s\n' "$out" | grep -c '^  ok' || true)
    [ "$status" = 0 ] || fails=$((fails + 1))
}

# The verdict summary, the record, and the exit code. Call once, at the
# end; a check that never reaches it writes no record, and its absence
# is what the registry reads.
finish() {
    if [ "$fails" = 0 ]; then verdict=pass; else verdict=fail; fi
    echo "$NAME: $oks ok, $fails FAIL ($verdict)"
    record_write "$verdict" "$oks" "$fails" "$@"
    exit "$fails"
}

# The dated record: tests/bench/<board>/<date>.json, one file per day
# (a re-run overwrites its own day's row for the same check).
record_write() {
    _verdict=$1 _ok=$2 _bad=$3; shift 3
    REPO=$(cd "$(dirname "$0")/../.." && pwd)
    # shellcheck disable=SC2086
    VERSION=$(ssh $O "root@$HOST" '. /etc/os-release 2>/dev/null; echo $VERSION_ID' 2>/dev/null) || VERSION=""
    python3 - "$REPO" "$HOST" "$NAME" "$_verdict" "$_ok" "$_bad" "${VERSION:-unknown}" "$@" <<'P'
import datetime, json, os, sys
repo, host, name, verdict, oks, fails, version = sys.argv[1:8]
notes = " ".join(sys.argv[8:]) or None
day = datetime.datetime.now().strftime("%Y-%m-%d")
path = os.path.join(repo, "tests", "bench", host, f"{day}.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
rows = []
if os.path.exists(path):
    try:
        rows = json.load(open(path)).get("rows", [])
    except Exception:
        rows = []
rows = [r for r in rows if r.get("check") != name]
rows.append({"check": name, "verdict": verdict, "ok": int(oks),
             "fail": int(fails), "version": version, "notes": notes})
with open(path, "w") as f:
    json.dump({"board": host, "date": day, "rows": rows}, f, indent=2)
    f.write("\n")
P
}
