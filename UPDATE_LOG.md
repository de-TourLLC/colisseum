# Colisseum Update Log

Date: 2026-11-01

## Signature Pool No Longer Narrates the Design (Anti-AI Readability Fix)

The `signature` step runs last in every preset and rewrites integer literals as
`((#("phrase")+N))` / `((M-#("phrase")))`, drawing the phrase from
`src/steps/noise/signature.json`. The old phrase pool described the obfuscator's own
internals in plain English -- "permuting opcodes", "ChaCha20 keystream go brrr",
"planting decoy VMs", "polymorphic opcodes: 255 ways to say MOVE", "silent drift armed:
wrong answers only", "the attribution is welded to the keystream", "reformat this and it
dies". Those strings survive minification (they are live code, not comments), so every
build shipped a plaintext tour of its design **and** its defences. For an LLM or a human
reading the output, that is the single most useful artifact in the file: it names each
layer to undo and which transforms to avoid touching.

Changes:
- **`src/steps/noise/signature.json`**: the ~180-entry phrase pool was replaced with
  ~150 phrases that keep the playful tone but reveal nothing about the pipeline. None
  names a real technique or defence (VM, bytecode, opcode, ChaCha, Fibonacci/Zeckendorf,
  decoys, superoperators, tamper gate, honeypot/drift, beautifier detection, keystream,
  credit/keystream binding, etc.). A subset is deliberate misdirection -- it references
  techniques the pipeline does **not** use (RSA-4096, AES-256-GCM, WASM sandbox, JIT,
  homomorphic, blockchain, quantum) to send static analysis down dead ends. The `credit`
  field is unchanged, so the keystream-bound watermark and the readable attribution header
  behave exactly as before.
- No code changed: the `signature` step, its length-based number encoding, and the
  per-build selection are identical. Only the data pool changed, so all existing behaviour
  (including seeded reproducibility and the credit binding) is preserved.

Verified: a `Fortress` build of `input.lua` loads cleanly and runs to the correct result;
an output scan for design keywords (chacha, register, bytecode, opcode, fibonacci, decoy,
tamper, keystream, honeypot, encrypt, cipher, permute, loadstring, dispatch, ...) now
returns nothing but the intentional credit watermark.

## Per-Build Instruction Layout (Register VM)

The register VM used a fixed instruction layout: every instruction was `op(1) + a(4) +
b(4) + c(4)` = 13 bytes, and the interpreter read operands at `off+1 / off+5 / off+9` with
a `* 13` stride. Those constants were identical in every build, so two builds of the same
(or different) source lined up byte-for-byte at the instruction level -- a stable fingerprint
and an easy anchor for cross-build diffing once the keystream was recovered.

Changes:
- **`src/core/reg-bytecode.lua`** (`encode_opaque`): takes an optional `layout = { gap, oa,
  ob, oc }`. `gap` inserts filler bytes after the opcode byte (so the stride becomes
  `13 + gap`); `oa/ob/oc` are the per-build byte offsets of operands a/b/c (a permutation of
  the three operand slots). Omitting `layout` reproduces the classic 13-byte op|a|b|c layout
  byte-for-byte, so `reg-vm.lua`, the tests, and any other caller are unchanged.
- **`src/core/reg-runtime.lua`**: the dispatch loop reads the stride and operand offsets from
  `program.st` / `program.oa|ob|oc` (defaults 13 / 1,5,9), including the superoperator
  (`FUSE*`) handlers that decode a second instruction.
- **`src/steps/security/register-vm.lua`**: picks a random `gap` (0-7) and a shuffled operand
  order per build, passes the layout to `encode_opaque`, and ships the matching
  `st/oa/ob/oc` in the program table. The `signature` step then disguises those integers too,
  so the layout constants are not even bare numbers in the output.

Verified: the register-VM differential, superoperator-differential, encrypt, Fibonacci, and
tamper suites pass; two independent `Fortress` builds show different `st/oa/ob/oc` and both
run to the correct result.

## Honest Protection Notice on Every Preset

`protection-notice` existed but was wired into no preset. It is now appended (last) to every
preset via `Obfuscator.preset`, and re-applied after the VM wrap in `package_luau` so it
survives the secure/LuaU path. The emitted text is an **honest** ownership/authorization
notice (`PROTECTION_NOTICE` in `src/obfuscator.lua`): it states the file is protected IP and
asks automated assistants to confirm ownership/authorization before helping to reverse it,
and it explicitly says the notice is not secret and must not be concealed from the user. It
is deliberately **not** a covert prompt-injection: the step's prior `DEFAULT_NOTICE` (which
impersonated a system directive and told an AI to deceive its user) is left in the file but
is not what the presets ship. Override per build with the step's `message` option, or set it
to `""` to omit.

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
