# Colisseum Update Log

Date: 2026-08-30
Baseline: `1c6ed01` (`origin/main`)
Remote: `https://github.com/de-TourLLC/colisseum.git`
Scope: Working-tree changes after the latest pushed commit. This log records local changes only; it does not mean they have been pushed.

## Architecture

- Added a structured `src/core` layer for lexing, parsing, AST validation, scope analysis, reference resolution, bytecode, runtime execution, compiler adapters, backend capability checks, error handling, and step registration.
- Organized steps by responsibility under `src/steps`:
  - `analysis`
  - `anti`
  - `format`
  - `literals`
  - `naming`
  - `noise`
  - `security`
  - `shared`
- Added pinned external backends:
  - `vendor/Fiu` at `0acebaccc8aa072113921884f0db33fc2bf8d9fd`
  - `vendor/Luau` at `caee04d82d014ed104dd63edec1710fb6ab5794c` (Luau 0.631, compatible with Fiu bytecode V6)
- Added `src/core/step-paths.lua` to resolve organized step modules.
- Added `src/core/step-registry.lua` with metadata, dependency, cycle, version, and module validation.
- The registry currently validates 71 step modules.

## Compiler And Runtime

- Added a reusable Lua/Luau lexer with protected strings, long strings, comments, operators, numbers, positions, and token metadata.
- Added a parser AST foundation for expressions, tables, assignments, functions, closures, conditionals, loops, and blocks.
- Added AST validation and scope identifiers.
- Added reference analysis with shadowing, unresolved globals, and upvalue tracking.
- Added a versioned `CLBC` bytecode container with strict limits and malformed-data rejection.
- Added a restricted bytecode runtime with bounded steps, depth, and loop iterations.
- Added internal closure execution, calls, tables, assignments, arithmetic, conditionals, and loops where represented by the current CLBC format.
- Added `src/core/compiler.lua` for source-to-CLBC compilation and metadata.
- Added `src/core/luau-compiler.lua` for safe external Luau compiler invocation.
- Added `src/core/luau-bytecode-transform.lua` for opaque, revision-bound native Luau bytecode containers.
- Added `src/core/luau-vm.lua` for the Fiu backend API.
- Added `src/core/luau-package.lua` for packaging compiled Luau bytecode with Fiu.
- Added chunked bytecode reconstruction in Luau packages to avoid large `table.unpack` calls.
- Added `Obfuscator.parse`, `compile`, `compile_luau`, `inspect`, `execute`, `safe`, and `try` APIs.

## Obfuscation Steps

- Added and organized safe normalization and analysis steps for comments, whitespace, line endings, delimiters, operators, literals, numbers, strings, identifiers, budgets, dialect checks, and resource checks.
- Added scope-aware local and parameter renaming.
- Added static anti-deobfuscation tripwires with bounded insertion.
- Added bounded dead-code and table-noise generation.
- Added boolean noise and visual noise steps.
- Added field-index rewriting with optional safe global-base indirection.
- Added authenticated-string integrity metadata with an explicit host-verifier limitation.
- Added runtime and coroutine integrity analysis.
- Added control-flow flattening as a guarded, conservative step.
- Added protection notice support.
- Added multiple literal encoders, split-string handling, constant arrays, numeric canonicalization, quote normalization, and protected token formatting.
- Presets now include `Easy`, `Medium`, `Hard`, `Full`, and `Secure`.

## CLI

- Added root `cli.lua`.
- Added case-insensitive preset handling.
- Added `--LuaU` and `--Luau` target flags.
- Added `--secure` mode.
- Added `--compiler` and `--fiu` backend paths.
- Added ANSI terminal banner output on `stderr`.
- Added `NO_COLOR` support.
- Added explicit `colisseum:` error prefixes.
- Added validation for missing option values, unknown presets, input failures, compiler failures, and output failures.

## Security And Licensing

- Added centralized error handling in `src/core/errors.lua`.
- Added `PRODUCTION.md` with security boundaries and release requirements.
- Added `THIRD_PARTY_NOTICES.md` with Fiu, Luau, Prometheus, Hercules, IronBrew, and FiOne license information.
- Added `docs/LUAU_BACKEND.md` and `docs/BACKEND_CAPABILITIES.md`.
- Added `docs/ERROR_CODES.md`.
- Corrected the project security policy reference to AGPLv3 sections.
- Added offline vendor revision and license verification in `tools/verify-vendor-licenses.lua`.
- Added `.gitmodules` entries for the pinned Fiu and Luau backends.

## Build And Automation

- Added `.github/workflows/build.yml`.
- Added `tools/build-luau.bat`.
- Added `tools/run-luau-tests.bat`.
- Added a Luau smoke fixture in `tests/luau_smoke.luau`.
- Added `.gitignore` and `SETUP.md`.

## Tests

- Added the main LuaJIT regression runner in `tests/run.lua`.
- Added adversarial tests for renaming, protected tokens, bytecode references, runtime limits, CLI errors, and package chunking.
- Added deterministic fuzzing in `tests/fuzz.lua`.
- Added differential fixtures and testing in `tests/differential.lua`.
- Added Luau backend capability tests in `tests/luau_vm.lua`.
- Added focused groups for token-safe transformations, anti-deobfuscation, noise, authenticated strings, and new transformations.
- Latest local results:
  - Main suite: 6 passed, 0 failed.
  - Adversarial suite: 6 passed, 0 failed.
  - Fuzz suite: 365 passed, 0 failed.
  - Differential suite: 3 passed, 0 failed.
  - Backend suite: 6 passed, 2 skipped, 0 failed.
  - Vendor verification: passed.

## Benchmarks

- Added `benchmarks/run.lua` and supporting benchmark modules.
- Added preset, parser, bytecode, runtime, time, and memory measurements.
- Latest measured results are documented in `benchmarks/README.md`.

## Working-Tree Files

Tracked files modified after the baseline include:

- `README.md`
- `SECURITY.md`
- `cli.lua`
- `src/core/lexer.lua`
- `src/core/luau-compiler.lua`
- `src/core/luau-package.lua`
- `src/core/step-paths.lua`
- `src/obfuscator.lua`
- `src/steps/anti/anti-tamper.lua`
- `src/steps/catalog.lua`
- `src/steps/literals/numbers.lua`
- `src/steps/naming/name-generator.lua`
- `src/steps/security/crypto.lua`
- `src/steps/security/protection-notice.lua`
- `src/steps/security/vm.lua`
- `tests/adversarial.lua`

New project files include:

- `.gitignore`
- `PRODUCTION.md`
- `SETUP.md`
- `THIRD_PARTY_NOTICES.md`
- `docs/ERROR_CODES.md`
- `docs/LUAU_BACKEND.md`
- `src/core/*` support modules and tests
- `src/steps/*` organized step modules
- `tests/*` regression, fuzz, differential, group, and Luau fixtures
- `benchmarks/*`
- `tools/*`
- `vendor/Fiu`
- `vendor/Luau`

Unclassified local artifacts currently present:

- `output.lua`
- `test.lua`

## Verification Boundary

The local LuaJIT, parser, bytecode, runtime, fuzz, differential, benchmark, and license checks pass. Native Luau compiler/runtime execution remains environment-dependent and is covered by the repository build workflow; the local machine must provide CMake, a C++17 toolchain, and the generated Luau binaries before those checks can run locally.

## Post-Log Corrections

- Added automatic `--Roblox` compiler discovery without requiring `--compiler`.
- Added `vendor/luau-compile.bat` as the repository-local compiler entry point.
- Fixed Windows batch invocation by using `call` for `.bat` and `.cmd` compiler backends.
- Fixed the wrapper to propagate Luau build failures instead of returning success.
- Added `Obfuscator.package_luau` so source transformations run before VM packaging.
- Added Roblox host-environment packaging as an explicit opt-in mode.
- Removed source-mode dynamic loaders from the VM and crypto steps.
- Current direct command failure is now accurate: CMake is missing from the host.
- Installed CMake and Visual Studio C++ Build Tools on the development host.
- Built the pinned Luau 0.631 compiler and runtime under `build/luau/Release`.
- Corrected the compiler adapter to request Luau `--binary` output instead of text output.
- Corrected Windows temporary-file and executable path handling.
- Generated `output.lua` with `lua cli.lua --preset Full --Roblox --out output.lua test.lua`.
- Executed the generated single-file package with the built Luau runtime; it passed.
- Executed `official-test.lua` with the built Luau runtime; 48 tests passed, 0 failed, 0 skipped.
- Fixed Windows compiler adapter binary mode, path normalization, and temporary-file redirection.
- Fixed the Luau differential harness to execute inline fixtures on the official runtime.
- Confirmed the generated Roblox package executes successfully with `build/luau/Release/luau.exe`.
- Added safe global-base indirection to the organized `noise/field-index` step.
- Built Luau 0.631 locally with the installed CMake/MSVC toolchain.
- Confirmed `luau-compile` binary output is compatible with the pinned Fiu backend.
- Fixed CLI compiler discovery and Windows path/temporary-file handling.
- Confirmed `Easy`, `Medium`, `Hard`, `Full`, and `Total` Roblox packages execute under the official Luau runtime.
- Confirmed `official-test.lua`: 48 passed, 0 failed, 0 skipped.

## Native VM: Phase 3 And Correctness Audit (2026-08-31)

Scope: the Lua-target native bytecode VM (`src/steps/security/native-vm.lua`) and
the shared front end (`src/core/{parser,ast,bytecode,runtime,compiler}.lua`). All
changes local; nothing pushed.

Phase 3 — per-build VM hardening:

- Added per-build opcode permutation: every build shuffles the VM's opcode numbers
  (Fisher-Yates on the build seed) and remaps the compiled program and the embedded
  opcode table to match, so no two builds share a bytecode encoding.
- Rebranded the embedded interpreter's opcode dispatch from readable string
  comparisons (`op=="chunk"`) to a per-build `KAT` numeric enum table
  (`op==KAT.CHUNK`), lexer/VM style. Type guards such as `type(x)=="string"` are
  left untouched; only the `op`/`cop` dispatch and the method-receiver `.opcode`
  check are rebranded.
- Added a `skip_validate` argument to `Bytecode.encode` so the permuted program is
  validated only by the equally-permuted embedded VM.
- Bumped `native-vm` to version 2 and synced its `catalog.lua` entry (registry
  validates 72 step modules).
- Fixed a rebrand-pattern bug: some branches use `op == "..."` with spaces while
  others use `op=="..."`; the transform now tolerates whitespace around `==`.

Correctness audit — bugs found and patched (all were silent failures or hangs on
common Lua that the native VM previously mis-handled):

- `break` was entirely unimplemented: it parsed as a no-op identifier expression,
  so loops ran to completion (wrong results) and `while true do ... break end` hung
  forever. Added a `break` node through parser -> AST -> bytecode -> runtime with a
  `broke` flag that unwinds only the innermost loop and is saved/restored across
  closure calls.
- `function M.new(...)` (dotted) and `function M:get(...)` (method) definitions
  failed to parse, breaking Total on virtually all OOP code. Now desugared to a
  member assignment of an anonymous function; methods gain an implicit `self`.
- Semicolons were rejected: statement separators, empty statements, and trailing
  `;` now parse (block skips them; removed `;` from the compiler's unsupported set).
- Table constructors now accept `;` as a field separator (`{1;2;3}`) and a trailing
  separator before `}` (`{1,2,3,}`).

Verification:

- `tests/vm_coverage.lua`: 24/24 (10 new regression cases for the above).
- Full suite green: main 7, adversarial 6, differential 6, fuzz 365, all 6 group
  suites, registry validates.
- Differential (native runtime vs reference LuaJIT) across 20 constructs: 20/20.
- End-to-end `--preset Total` (Lua target) on OOP + break + semicolons + mixed
  table separators + closures + recursion + `gmatch`: builds, 0 `loadstring`,
  per-build `KAT` enum and `_KAT` markers, output matches the reference.
- Known native-target limitations (rejected cleanly, handled by the Luau/Fiu
  backend instead): `goto`/labels, `continue`, and bitwise operators.

## Unified Native VM Backend For Lua And Luau (2026-08-31)

The native KAT VM is now the default backend for BOTH the Lua and the Luau/Roblox
targets; Fiu becomes opt-in. This removes the readable interpreter that the Fiu
path used to ship.

- The native VM's single output already runs on both Lua/LuaJIT and Luau/Roblox:
  the ChaCha decryptor uses `bit32 or bit`, the runtime uses no bitwise ops, and
  `table.unpack or unpack` is handled. It is fully obfuscated (per-build opcode
  permutation + KAT enum, encrypted bytecode, minified interpreter, no readable
  identifiers), unlike Fiu.
- Native output now resolves host globals from `getfenv(0)` (the running script's
  environment: Roblox/Luau `print`, `game`, `task`, ...) and falls back to `_G`,
  so it works under Roblox where host globals do not live in `_G`. Verified under
  the official `luau.exe`.
- `src/steps/security/vm.lua` dispatches on `options.backend`: `native` (default,
  both targets, no compiler) or `fiu` (real Luau bytecode, full Luau syntax,
  requires the Luau compiler).
- `Obfuscator.package_luau` gained a `backend` option and only requires the Luau
  compiler for the Fiu backend.
- CLI: added `--backend native|fiu`; `--fiu <path>` implies the Fiu backend.
  `--secure` now defaults to the native backend and no longer requires `--LuaU`
  or a compiler; `--backend fiu` still requires both.
- The Fiu backend, when used, now ships minified (comments and formatting stripped
  via the token-based minifier, which is Luau-safe). Scope renaming is NOT applied
  to Fiu: the native renamer corrupts `local x = x` global-localization patterns
  (it renames the right-hand global too) and other Luau constructs, producing a VM
  that calls a nil value. Left as a known limitation of the Fiu path; the native
  backend has no such issue.

Verification: full suite green (main 7, adversarial 6, differential 6, fuzz 365,
vm_coverage 24, all groups, registry). `--preset Full --secure --LuaU` and
`--preset Total` both produce native-VM output that executes correctly under both
LuaJIT and the official `luau.exe` (0 `loadstring`, no `__fiu`, per-build KAT enum).

## Native VM Performance Pass (2026-08-31)

Optimized the tree-walking interpreter's hot paths (`src/core/runtime.lua`) with no
change to semantics; full suite stays green and the shipped output still runs on
both LuaJIT and Luau.

- Hoisted the hot library functions (`type`, `tonumber`, `select`, `setmetatable`,
  `math.floor`, ...) into module locals.
- Inlined `tick()`/`enter()`/`leave()` into `eval`/`execute` and read the step,
  depth, and loop-iteration ceilings from cached locals instead of table fields.
- Reordered `eval`'s dispatch chain so the hottest opcodes (identifier, binary,
  call, index/member) are tested first; the identifier branch returns early.
- Merged each scope's `values`+`declared` tables into a single `values` table with
  a `NIL` sentinel for declared-nil, cutting one table allocation per scope/call
  and one hash lookup per variable read.
- KAT enum constants are now flat locals (`op==KAT_CHUNK`) instead of a `KAT.CHUNK`
  table field, so each dispatch comparison is a register read rather than a hash
  lookup -- and it reads like a real lexer/VM `TK_*` enum. Verified to stay within
  the LuaJIT 60-upvalue-per-function cap.

Measured (LuaJIT, min-of-N): loop-heavy and table-heavy workloads improved ~1.5x-2.3x;
string building ~1.7x. Deep recursion (fib) is dominated by per-call allocation
(args table, return pack, closure env) inherent to a tree-walker calling real Lua
closures, and improved only marginally. A register-based bytecode VM would be the
next step to close the remaining gap to Prometheus/Luraph-class VMs on raw compute;
it is a larger, separate effort.

## Register VM Backend (2026-08-31)

Added a NEW register-based bytecode VM as the fast, third obfuscation backend,
alongside the tree-walking native VM (default) and Fiu. It is 2-6x faster than the
tree-walker and runs on both Lua/LuaJIT and Luau/Roblox with no loadstring.

New core modules (the tree-walker is untouched):
- `src/core/reg-bytecode.lua` - register ISA (43 opcodes), RK constant operands,
  boxed-upvalue cells, and a compact binary encode/decode (magic `CLRV`).
- `src/core/reg-compiler.lua` - AST -> register bytecode: single-pass codegen with
  a register allocator, constant interning, jump patching, a capture pre-pass that
  boxes captured locals for correct upvalue semantics, and Lua-correct multi-value
  alignment for calls/returns/varargs/table constructors.
- `src/core/reg-runtime.lua` - the interpreter: a dispatch loop over a per-frame
  register file. Uses raw Lua operators for arithmetic/compare/index/concat, so
  coercion, metamethods, and errors match reference Lua exactly. VM closures are
  real Lua functions (host pcall/sort/ipairs/metamethods call them directly).
- `src/core/reg-vm.lua` - facade `execute(source, options)`; resolves host globals
  via getfenv(0) then _G.

Obfuscation integration:
- `src/steps/security/register-vm.lua` - compiles to register bytecode, applies a
  per-build opcode permutation (remapping the program and reordering the embedded
  opcode table), ChaCha20-encrypts the bytecode (no loadstring), and embeds the
  minified decoder + interpreter with `_KAT` per-build markers. Runs on both
  runtimes via portable bit32/bit and getfenv(0)/_G.
- `src/steps/security/vm.lua` dispatches `options.backend == "register"`.
- CLI `--backend register`; `Obfuscator.package_luau` now strips the preset's own
  `vm` step before applying the chosen backend, fixing a double-VM packaging bug
  (a preset such as `total` carries a `vm` step, which previously ran in addition
  to the backend's, so the register VM was compiling native-vm's output chunk).

Acceptance:
- `tests/reg_vm_differential.lua`: 55/55 vs reference Lua (closures, upvalues,
  varargs, methods, metatables, generic-for, multi-value, break, recursion, string/
  table library, pcall).
- Benchmark vs the tree-walker (LuaJIT, min-of-N): fib 2.5x, tight numeric loop
  6.2x, table build 6.2x, method calls 2.2x.
- Existing suite untouched and green (run 7, vm_coverage 24, adversarial 6,
  differential 6, fuzz 365, all groups, registry validates).
- `--preset Total|Full --backend register` executes correctly under both LuaJIT
  and the official luau.exe, 0 loadstring, per-build opcode permutation (distinct
  builds).

Known native/register parser limits (unchanged): goto/labels, continue, bitwise
operators are rejected cleanly; use `--backend fiu` for full Luau syntax.


## Register VM Output Hardening (2026-08-31)

Removed the HTTPS licensing experiment (worker, license-loader, chacha, --license)
and instead hardened the client-side register-VM output.

- The embedded interpreter's own identifiers are now mangled per build: the
  register-VM backend runs the `rename` step over the permuted `reg-bytecode` and
  `reg-runtime` sources before minifying, so `execute_proto`, `make_closure`, the
  register file, and the opcode locals ship as `itzCool_*` soup (~179 renamed
  identifiers) instead of a readable register VM. The `.OP/.NAME/.decode` field
  interface between the two embedded modules is preserved (rename never touches
  table keys), and the pass is guarded so a rename failure just ships the minified
  unrenamed source.
- `reg-runtime.lua` no longer localizes globals with a self-shadowing `local x = x`
  (which the token renamer would rewrite to nil); the localizations use distinct
  names, so the interpreter is rename-safe when embedded.
- Combined with what was already there -- ChaCha20-encrypted bytecode (with an FNV
  integrity check), per-build opcode permutation, `_KAT` markers, no loadstring --
  each build is fully distinct and carries no readable VM.

Verified: full suite green (run 7, vm_coverage 24, reg_vm 55/55, adversarial 6,
fuzz 365, all groups, registry); `--backend register` executes correctly under both
LuaJIT and luau.exe; builds are distinct.
