#!/bin/sh
# bench/lib-remote.sh: the harness's board-side half. A check ships this
# beside its own body (the local lib.sh does the shipping), so ok/bad,
# the verdict summary and the one Varlink caller are written once for
# every check (review 2026-10-17, KRN-04). POSIX sh: the image's shell
# is busybox.

fails=0
oks=0
ok()  { oks=$((oks + 1)); echo "  ok    $*"; }
bad() { fails=$((fails + 1)); echo "  FAIL  $*"; }

# A row whose probe failed is a FAIL, never an absent pass (CON-08,
# review 2026-10-17): an empty or error reply through this helper is a
# failure that says so.
varlink() {
    python3 - "$1" "${2:-{\}}" <<'P'
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX); s.connect("/run/vrx/io.vrx.Host")
    s.sendall(json.dumps({"method": sys.argv[1], "parameters": json.loads(sys.argv[2])}).encode() + b"\0")
    print(s.recv(65536).decode().rstrip("\0"))
except OSError as e:
    print(json.dumps({"error": "io.vrx.Host.Unavailable", "parameters": {"detail": str(e)}}))
P
}

# The summary line; the exit code is the caller's (a check ends with
# `exit $fails`, its last line).
summary() {
    name=${0#/tmp/vrx-bench-}
    echo "$name: $oks ok, $fails FAIL"
}
