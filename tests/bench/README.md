# bench records

One JSON file per board per day, written by `tools/bench/lib.sh`'s
`finish` (review step 40): every check that ran, its verdicts, and the
image version it ran against. This is "what was verified", as a file —
a board half whose newest record predates the change that touches it
reads as unverified, not as done.
