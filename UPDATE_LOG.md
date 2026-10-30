# Colisseum Update Log

Date: 2026-10-30

## Own-VM Luau Semantics, Modern Syntax, and a Crypto/Hardening/Perf Pass (Fiu Removed)

This pass makes the obfuscator's own VM backends (register and native) run the Luau
subset that matters for Roblox -- overloaded-operator types and modern syntax -- and
retires the external Fiu backend so there is a single, self-contained runtime. It also
widens the cipher key derivation, adds register-VM hardening, an opt-in constant cache,
and a few correctness/robustness fixes. Behaviour was cross-checked against the vendored
Luau build; a new differential runner pins it.

Changes:
- **Overloaded-operator arithmetic** (`src/core/reg-runtime.lua`, `src/core/runtime.lua`):
  both VMs now evaluate `+ - * / % ^` and unary `-` with native operators, so userdata
  with metamethods (Vector3, CFrame, UDim2, Color3) works. The register VM's silent
  honeypot drift is applied only to numeric results, so a clean run no longer adds `0`
  to a Vector and errors; the native VM dropped the `number()` operand guards that
  rejected non-number operands. This is the fix that let Fortress run real Roblox code.
- **`__call` and `__len` metamethods** (`src/core/reg-runtime.lua`): `CALL` now accepts
  a callable table/userdata (invokes `__call`) instead of rejecting a non-function
  callee, and `#` honours `__len` explicitly so a table length behaves the same on Lua
  5.1 and Luau (5.1 ignores `__len`; the Luau target honours it).
- **Modern Luau syntax on the own VM** (`src/core/lexer.lua`, `src/core/parser.lua`,
  `src/core/reg-compiler.lua`, `src/core/interp-lower.lua`): `continue` (a contextual
  statement, compiled to a jump to each loop's continue point), string interpolation
  (`` `text {expr}` ``), the `if ... then ... else ...` expression, numeric digit
  separators (`1_000_000`), and the `\u{XXXX}` escape. Interpolation and if-expressions
  are lowered to plain Lua up front (`interp-lower`), so the renamer and the validator
  see ordinary code; the parser also understands them directly for callers that bypass
  the pipeline.
- **Fiu backend removed** (`src/steps/security/vm.lua`, `cli.lua`): `--backend fiu`,
  `--fiu`, and routing to the Fiu VM now error. Colisseum runs only on its own register
  and native VMs; no external Luau compiler is on the obfuscation path.
- **Call-sugar-safe authenticated strings** (`src/steps/anti/authenticated-strings.lua`):
  the per-string wrapper is parenthesised as a single primary expression, so
  `print "x"` lowers to `print((...))` and not `print(fn)(...)`. Also fixed a
  reproducibility bug -- a per-process build counter was folded into the key even with
  an explicit seed, so seeded builds were not byte-identical; the counter is now used
  only for unseeded uniqueness.
- **Shell-safe external compiler and batch dir** (`src/core/luau-compiler.lua`,
  `cli.lua`): the compiler invocation quotes both redirection targets (a temp path with
  a space or a hostile `TEMP` no longer breaks or injects), and `--batch` rejects an
  output directory containing shell metacharacters before it reaches `os.execute`.
- **Wide ChaCha key derivation** (`src/core/chacha.lua`, `src/core/reg-runtime.lua`):
  the per-build key and nonce are now folded through four independent 32-bit states and
  mixed into every output byte, instead of collapsing the fog to a single 32-bit value.
  The RFC 8439 block function and the build/runtime keystream agreement are unchanged
  (reg_vm_encrypt KAT green); derivation runs once at VM start.
- **Stronger seed entropy** (`src/core/entropy.lua`): `collect()` mixes bytes from
  `/dev/urandom` where available (POSIX), falling back to the previous time/ASLR
  material elsewhere, so unseeded builds are unpredictable, not merely unique.
- **More superoperators** (`src/core/reg-bytecode.lua`, `src/core/reg-runtime.lua`,
  `src/steps/security/register-vm.lua`): added the cross-kind fusions `MOVE;LOADK`,
  `LOADK;MOVE`, `MOVE;GETGLOBAL`, `GETGLOBAL;MOVE`, `LOADK;GETGLOBAL`, `GETGLOBAL;LOADK`
  to the existing identical-pair fusions. Each enabled per build; fewer dispatch
  iterations and less 1:1 opcode-to-operation mapping.
- **Blob fragmentation** (`src/steps/security/register-vm.lua`): the bytecode blob
  ships as several string literals concatenated at load, not one contiguous literal, so
  it is not a single string to a dump or a grep. The reconstructed stream is identical.
- **Blob self-hash** (`src/steps/security/register-vm.lua`, `src/core/reg-runtime.lua`):
  the interpreter recomputes an FNV hash of its own byte stream at start against a value
  baked at build time, and latches the silent honeypot drift on a mismatch, so a patch
  to the blob in memory quietly corrupts results.
- **Opt-in constant cache** (`--cache`; `src/core/reg-runtime.lua`, `src/obfuscator.lua`,
  `cli.lua`): decodes each VM constant from the fogged blob once and reuses it instead
  of rebuilding strings/numbers on every access. Off by default (the maximum-security
  build keeps the decode-on-demand property); roughly a 2.5x runtime win on a
  constant-heavy loop in the local benchmark.
- **Unbranded identifiers** (`--no-brand`; `src/obfuscator.lua`,
  `src/steps/security/register-vm.lua`, `src/steps/security/native-vm.lua`): generated
  identifiers use a per-build random prefix instead of the fixed `coli_`, for builds
  that should carry no fixed brand string in their names. Default is unchanged; the
  signature line is unaffected.
- **Tooling** (`tests/conformance.lua`, `cli.lua`, `benchmarks/overhead.lua`): a
  register-VM conformance/differential runner (baseline Lua plus the new Luau features,
  metamethods, coroutines, and a reproducibility check); a `--verify` flag that loads
  the output to confirm it compiles, not just that brackets balance; and a runtime
  overhead benchmark (register VM vs native, with and without `--cache`). `fortress` was
  added to the preset benchmark.

Verified: reg_vm_differential 60/60, reg_vm_superop_differential 18/18, reg_vm_encrypt
9/9 (incl. ChaCha20 RFC 8439 KAT), reg_vm_tamper 4/4, reg_vm_fibonacci 10/10,
conformance 56/56, fibonacci 10016, numeric_fibonacci 16/16, run 9/9, differential 6/6,
vm_coverage 29/29, adversarial 7/7, fuzz 365/365, group suites and Luau smoke green. All
presets run with no `load`/`loadstring`; the new Luau syntax, overloaded-operator types,
`__call`/`__len`, and seeded reproducibility were cross-checked against the vendored
Luau build.
