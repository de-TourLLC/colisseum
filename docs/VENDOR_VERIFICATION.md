# Offline Vendor Verification

Run this command from the repository root:

```text
luajit tools/verify-vendor-licenses.lua
```

The verifier is intentionally offline. It reads the local notice and license
files and uses `git rev-parse` only to read each checked-out submodule commit.
It does not fetch, update, or initialize submodules, and it does not load or
execute code from `vendor`.

The expected revisions are recorded in the script. Update those values and the
notice requirements together when intentionally changing a vendor pin.
