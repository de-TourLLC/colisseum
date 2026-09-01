<p align="center">
  <img src="./img/brand.png" alt="Colisseum">
</p>
<p align="center">A security-focused obfuscator for Lua and Luau.</p>

<p align="center">
  <img alt="License" src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg">
  <img alt="Targets" src="https://img.shields.io/badge/targets-Lua%20%7C%20Luau-informational.svg">
  <img alt="Status" src="https://img.shields.io/badge/status-active%20development-orange.svg">
</p>

---

## Overview

Colisseum transforms Lua and Luau source into a hardened, functionally equivalent
form that is substantially harder to read, analyze, and reverse-engineer. It runs
as a layered pipeline: each build applies a configurable sequence of
transformations and re-validates the result so it stays valid, executable code.

Colisseum is under active development. Its not finished yet lolz

## Features

- **Lua and Luau targets** | pick the dialect that matches your runtime.
- **Preset-based protection** | from lightweight to maximum, selectable per build.
- **Unique on every build** | the same input yields a different output each run
  (independent identifiers, values, and layout), with no fixed signatures. An
  explicit seed can be supplied for reproducible builds.
- **Single-line output** | every preset emits the result on one physical line.
- **Layered transformations** | confusable identifier renaming, number-to-expression
  and literal rewriting, string pooling / splitting / encryption, dead-code, decoy
  functions, opaque predicates, control-flow flattening, structural noise, runtime
  integrity and anti-tamper checks, and layered payload encryption.
- **Runtime-safe** | heavy decode loops yield cooperatively, so large scripts do
  not trip the Roblox execution-time watchdog ("exhausted allowed execution time").
- **Tamper aware** | the output detects debug hooks, replaced globals, and
  executor / injector environments, and fails with a branded, coded error
  (see [docs/ERROR_CODES.md](docs/ERROR_CODES.md)).
- **Verified output** | every build is re-validated to remain syntactically
  correct and runnable.

## Usage

```
lua cli.lua --preset <Easy|Medium|Hard|Full|Total> --out output.lua input.lua
```

Many files at once (`--out` is a directory):

```
lua cli.lua --preset Total --batch --out out_dir file1.lua file2.lua ...
```

Secure Luau packaging (builds the bundled Luau once; the CLI then finds it
automatically):

```
tools\build-luau.bat
lua cli.lua --preset Full --secure --LuaU --out output.lua input.lua
```

See [SETUP.md](SETUP.md) for full setup and usage.

### Presets

| Preset   | Protection |
| -------- | ---------- |
| `Easy`   | Minification and identifier renaming. |
| `Medium` | Renaming, number-to-expression and literal transforms, integrity and anti-tamper checks. |
| `Hard`   | Medium, with added dead-code, decoy functions, opaque predicates, and structural noise. |
| `Full`   | Maximum standard protection, including layered payload encryption and a runtime wrapper. |
| `Total`  | Full, with control-flow flattening, string pooling / splitting, and extra protection layers. |
| `Secure` | Full-level protection packaged to Luau bytecode via the bundled toolchain (`--secure`). |

Heavier presets trade size and startup for protection: `Easy`/`Medium`/`Hard`
stay compact, while `Full`/`Total` produce larger output with layered encryption.

## Requirements

- A Lua 5.1+ / LuaJIT interpreter to run the obfuscator.
- For the secure Luau path: the Luau toolchain, provided as a submodule — clone
  with `--recurse-submodules`.

## Security and limitations

Obfuscation raises the cost of analysis; it is not encryption, not an access
control, and not a guarantee against reverse-engineering. Do not place secrets,
keys, or credentials in code you distribute. Review and test every build in an
isolated environment before use. See [SECURITY.md](SECURITY.md) for the security
policy and [PRODUCTION.md](PRODUCTION.md) for production boundaries.

## License

Colisseum is licensed under the GNU Affero General Public License v3.0 — see
[LICENSE.md](LICENSE.md). Third-party components and their obligations are listed
in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).