# Setup & Usage

Colisseum is a Lua/Luau source obfuscator. `cli.lua` is a Lua 5.1 / LuaJIT script,
so you need a Lua interpreter to run it. Run every command from the repository root.

## Requirements

- A **Lua 5.1** or **LuaJIT** interpreter on your `PATH` (the `lua` command).
- Only for `--secure`: **CMake** and a C++ toolchain to build the bundled Luau,
  with the submodules checked out:

```bat
git submodule update --init --recursive
```

## Obfuscate (normal)

```bat
lua cli.lua --preset Total --out output.lua input.lua
```

Replace `input.lua` with your file and `output.lua` with the destination.
Presets: `Easy` | `Medium` | `Hard` | `Full` | `Total`.

## Obfuscate with the repo's Luau (`--secure`)

Build the bundled Luau once. Afterwards the CLI finds it automatically at
`build\luau\Release\luau.exe` — you do not need to pass `--compiler`:

```bat
tools\build-luau.bat
```

Then obfuscate and package to Luau bytecode:

```bat
lua cli.lua --preset Full --secure --LuaU --out output.lua input.lua
```

All preset outputs are emitted on a single physical line.

## Many files at once (batch)

`--out` becomes an output directory:

```bat
lua cli.lua --preset Total --batch --out out_dir file1.lua file2.lua file3.lua
```

## Presets

| Preset   | Protection |
| -------- | ---------- |
| `Easy`   | Minification and identifier renaming. |
| `Medium` | Renaming with literal/number transforms and integrity checks. |
| `Hard`   | Medium plus dead-code and structural noise. |
| `Full`   | Maximum standard protection, including payload encryption. |
| `Total`  | Full plus extra literal-protection and control-flow layers. |

## Optional: bundle the interpreter in the repo

To avoid depending on a system-wide `lua`, copy your LuaJIT into a `bin\` folder
and call it directly (LuaJIT needs `lua51.dll` next to the executable):

```bat
mkdir bin
copy "<path-to>\luajit.exe" bin\
copy "<path-to>\lua51.dll" bin\
bin\luajit.exe cli.lua --preset Total --out output.lua input.lua
```
