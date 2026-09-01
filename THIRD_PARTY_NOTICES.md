# Third-Party Notices

Colisseum is distributed under the license in `LICENSE.md` (GNU Affero General
Public License v3.0). It bundles the third-party components below under
`vendor/`. When you redistribute Colisseum or its output, preserve the notices
and satisfy the obligations that apply to the components you actually include.

## Fiu — `vendor/Fiu` (MIT License)

A Luau bytecode interpreter used by the optional secure-packaging backend.

```
Copyright (c) 2022-2024 TheGreatSageEqualToHeaven
Copyright (c) 2019-2024 Roblox Corporation
Copyright (c) 1994-2019 Lua.org, PUC-Rio.
```

The MIT license text and its disclaimer of warranty must be preserved when
redistributing a copy or a substantial portion. The license grants no rights over
trademarks.

## Luau — `vendor/Luau` (MIT License)

The Luau language toolchain, used as the optional `--secure` compiler.

```
Copyright (c) 2019-2025 Roblox Corporation
Copyright (c) 1994-2019 Lua.org, PUC-Rio.
```

The MIT license text and disclaimer must be preserved on redistribution.

## Maintenance note

Licenses and repositories can change. Before incorporating any code, pin a
specific revision, re-check its `LICENSE`/`NOTICE` and in-file notices, and update
this document. This audit is informational and does not replace a legal review of
the specific combination you ship.
