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
