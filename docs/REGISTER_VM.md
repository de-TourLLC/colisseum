# Register VM Backend (design contract)

Goal: a register-based bytecode VM for Colisseum's Lua target that is materially
faster than the existing tree-walking interpreter (`src/core/runtime.lua`) on
compute-heavy code, to close the gap to Prometheus/Luraph-class VMs. It is a NEW,
isolated backend: the tree-walker stays the default and is never modified in a way
that breaks it.

## Non-negotiable constraints

- **No `loadstring`/`load`** anywhere in the compiler, the VM, or any output.
- **Runs on both Lua/LuaJIT and Luau/Roblox.** Use only the common subset: no
  bitwise operators in the VM itself; use `bit32 or bit` if bit ops are ever
  needed; `table.unpack or unpack`; resolve host globals via `getfenv(0)` then
  `_G` (mirror `src/steps/security/native-vm.lua`).
- **Same language surface as the tree-walker**: locals, assignment, multiple
  assignment, `if/elseif/else`, `while`, `repeat/until`, numeric `for`, generic
  `for` (Lua iterator protocol), functions/closures/upvalues, varargs, method
  defs (`a:m`) and calls, dotted defs (`a.b.c`), `break`, tables (array/hash/mixed/
  nested/computed keys), metatables via host `setmetatable`, method chaining,
  multi-value calls/returns aligned to Lua semantics, `and`/`or` short-circuit,
  length `#`, concat, all arithmetic/comparison operators, `nil` handling.
- VM closures must be **real Lua functions** so host code (`pcall`, `table.sort`,
  metamethods, callbacks, `ipairs`/`pairs`) can call them directly — same as the
  tree-walker.
- Bounded execution: keep step/depth/loop ceilings (may be generous).

## API contract (what tests call)

```lua
local RegVM = require("src.core.reg-vm")
-- Compile `source` (a Lua string) to register bytecode and run it, returning a
-- table of the chunk's return values (result[1] is the first). Semantics MUST
-- match reference Lua exactly. `options` may carry { environment = <table> } and
-- limit overrides, mirroring Runtime.run.
local results = RegVM.execute(source, options)
```

`tests/reg_vm_differential.lua` is the acceptance target: every case must equal
reference Lua. It may be run with `luajit tests/reg_vm_differential.lua`.

## Suggested internal structure (not mandatory, but this shape integrates cleanly)

- `src/core/reg-bytecode.lua` — a register ISA: a flat instruction stream per
  proto (function), a constants pool, nested protos for closures, upvalue
  descriptors. `encode`/`decode`/`validate`, an `opcodes()` map (name->number)
  and a contiguous opcode numbering so a later step can permute it. No source
  text or plaintext survives a round-trip beyond constants.
- `src/core/reg-compiler.lua` — AST (from `src.core.parser`) -> register
  bytecode: register allocation, constants interning, jump emission/patching for
  control flow, upvalue capture, proto nesting, correct multi-value `CALL`/
  `RETURN`/`VARARG`/`SETLIST` alignment.
- `src/core/reg-runtime.lua` — the interpreter: a dispatch loop over the
  instruction stream with a register file, constants, upvalues, and closures as
  real Lua functions. Prefer a numeric opcode dispatch (a jump/dispatch table
  keyed by opcode is ideal for speed and obfuscation).
- `src/core/reg-vm.lua` — thin facade exposing `execute(source, options)` =
  parse -> compile -> run.

## Acceptance

1. `tests/reg_vm_differential.lua` passes 100%.
2. The existing suite is untouched and still green: `tests/run.lua`,
   `tests/vm_coverage.lua`, `tests/adversarial.lua`, `tests/differential.lua`,
   `tests/fuzz.lua`, `tests/groups/*.lua`.
3. A microbenchmark shows the register VM beating the tree-walker on
   `fib`, a tight numeric loop, and table building (in-process, min-of-N).

Integration into the obfuscation pipeline (ChaCha seal, per-build opcode
permutation + KAT enum, the `reg-vm` security step, and the CLI `--backend`
option) is done AFTER the core lands and is NOT part of the core agent's task.
