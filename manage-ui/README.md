# The management page

The page vrx-manage serves (plan 0008 Part G): evrx-rt's `manage-ui`,
built, copied here unchanged from evrx-rt commit 51d7960 (2026-10-12).
`dist.json` lists every file with its sha256 and the source tree's hash;
the files were checked against it when copied. The page's source and
its build (`scripts/build_manage.sh`) live in evrx-rt; to update, rebuild
there and copy `dist/` and `dist.json` again.

It reads `/api/status` and `/api/log`, the contract in evrx-rt's
`docs/47-management-api.md`, which vrx-manage (`rust/manage`) answers
from Linux. Files are stored gzipped and sent with
`Content-Encoding: gzip`.

## vrx's own pages

`dist/` above is evrx-rt's page, unchanged. Pages vrx adds live as readable
source in `vrx/` and are served from gzipped copies in `dist/`:

| Source | Served at | What |
|---|---|---|
| `vrx/update.html` | `/update/` | send a software update bundle to the device (plan 0016 D11) |

`cargo xtask manage-page` writes the copies (`gzip -n -9`, so the bytes depend
only on the source); the gate fails when a copy no longer unpacks to its
source. A page takes its limits from the API (`GET /api/update` says how
large an update may be and how much room is left), never its own numbers.
The vendored page gains a link to `/update/` the next time it is rebuilt in
evrx-rt; until then the address is typed, or opened from the device's Manage
applet.
