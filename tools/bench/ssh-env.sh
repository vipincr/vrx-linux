#!/bin/sh
# bench/ssh.sh: the one ssh option set every bench check uses (review
# 2026-10-17, SEC-04): the board's key is KNOWN, written at flash time by
# `bench-known <host>`, and ssh refuses a changed key instead of blindly
# trusting whatever answers. Until a board's key is known, StrictHostKeyChecking=accept-new
# takes it the first time (a bench LAN, not the internet).
OPTS="-o LogLevel=ERROR -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$VRX_BENCH_KNOWN_HOSTS"
[ -n "${VRX_BENCH_KNOWN_HOSTS:-}" ] || OPTS="-o LogLevel=ERROR -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
