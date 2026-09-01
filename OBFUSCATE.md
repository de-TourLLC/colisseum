# Obfuscating with full security

## The command

Maximum client-side hardening on the fast register VM (`fortress` preset):

```bash
lua cli.lua --preset fortress --LuaU --out output.lua input.lua
```

- Use `luajit` instead of `lua` if that is your interpreter.
- Drop `--LuaU` for a plain Lua target — the output runs on both anyway, but
  `--LuaU` erases Luau type syntax up front so Luau sources compile cleanly.
- Replace `input.lua` with your script and `output.lua` with the file to write.

The build shows a live progress bar with an ETA while it works.

## Run the obfuscated file

**With the bundled Luau runtime:**

```bash
build\luau\Release\luau.exe output.lua
```

**On Roblox:** paste the contents of `output.lua` into a `Script` / `LocalScript`
/ `ModuleScript`. It runs natively — no extra runtime needed.

**Plain Lua / LuaJIT** (if you obfuscated without `--LuaU`):

```bash
luajit output.lua
```

## Obfuscate several files at once

```bash
lua cli.lua --preset fortress --LuaU --batch --out out_dir file1.lua file2.lua file3.lua
```

## What `fortress` does

Every static layer feeds the register VM, so the runtime stays fast while a
deobfuscator has to peel everything off:

- Control-flow flattening + opaque predicates
- Triple string encryption (authenticated + byte-encoding + encrypted) and
  constant arrays / split strings / field indirection
- Scope renaming (`itzCool_...`)
- Anti-tamper with executor + timing detection, runtime integrity
- **Register VM backend**: ChaCha20-encrypted bytecode, per-build opcode
  permutation, a name-mangled interpreter, `_KAT`-free `coli_` markers, and
  **no `loadstring`**
- Cooperative auto-yield (`task.wait`) so heavy loops do not trip Roblox's
  execution-time limit
- Output collapsed to a **single line**, and **every build is different**

## Backends (optional)

| Flag | Backend | Notes |
|------|---------|-------|
| *(default)* | `register` in `fortress` | Fastest; runs on Lua + Luau/Roblox; no compiler needed |
| `--backend native` | tree-walking VM | Also portable, slower |
| `--backend fiu` | real Luau bytecode VM | Full Luau syntax (`continue`, generics, string interp); needs `--LuaU` + the Luau compiler |

## Honest note

This is client-side obfuscation: encryption + permutation + mangling make it
**expensive and slow to reverse**, and each build is unique, but nothing
client-side is truly uncrackable. The goal is to make the attacker suffer, not to
be impossible.
