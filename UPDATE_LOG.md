# Colisseum Update Log

Date: 2026-09-11

## Real Cipher + Fibonacci Layer + In-VM Tamper Gate + False Paths

A large hardening pass on the register VM (the Fortress backend), plus a size/dead-
code amplifier, a Fibonacci coding system, a new literal step, and richer, more
developer-legible error codes. Everything below is per-build, semantics-preserving,
and verified on both LuaJIT and Luau/Roblox.

Changes:
- **Bounded bloat amplifier** (`--bloat N`, 1-16; `src/obfuscator.lua`): one knob
  scales the injected dead code (all provably unreachable and syntactically
  validated) across *every* preset. Each budget is clamped to a per-key ceiling, so
  output grows large-but-finite and still loads under Roblox/Luau script-size and
  parser limits. The per-step hard caps and source guards were raised to give the
  amplifier headroom without removing the ceiling.
- **Fibonacci (Zeckendorf) coding system** (`src/core/fibonacci.lua`,
  `--fibonacci`): a self-delimiting integer/byte codec (greedy Zeckendorf
  decomposition, usage bits + terminal `1`). The register-VM bytecode blob can be
  carried as bit-packed Fibonacci codewords -- re-encoding every numeric constant,
  operand, and offset -- and is rebuilt once at VM start (the hot loop is untouched).
- **Real ChaCha20 stream cipher on the register VM** (`src/core/chacha.lua`,
  `--encrypt`, default in Fortress): the fogged bytecode blob is now XOR-masked with
  an RFC 8439 ChaCha20 keystream (KAT-verified) instead of an ad-hoc hash keystream.
  The keystream is derived from the per-build fog once at VM start, so the decoded
  program still never materializes in memory and the hot loop is unchanged.
- **In-interpreter tamper gate** (`src/core/reg-runtime.lua`, `--vm-guard`, default
  in Fortress): a startup scan bound INTO the interpreter (not a strippable payload
  guard) latches the silent honeypot drift if a debug hook is installed or a decisive
  executor/injector marker is present -- so results quietly diverge, with no branded
  error to point at the check, and unwinding the compiled-in anti-tamper still leaves
  this backstop.
- **VM-first layout + false paths** (`src/steps/security/register-vm.lua`): the
  bundle now opens with the interpreter itself and shuffles the payload/env locals
  together with the decoy noise, so there is no leading junk prologue to strip and no
  contiguous VM block to lift. Added **decoy VM routes**: dead, provably-false
  branches carrying payload-shaped blobs, a decoy integrity checksum, a branded abort
  code, and a `pcall`-wrapped decoy `R.run` -- a deobfuscator now sees several `.run`
  calls and blobs to disprove, at zero runtime cost.
- **New `numeric-fibonacci` step** (`src/steps/literals/numeric-fibonacci.lua`):
  rewrites bounded integer literals as indexed reads from a pool decoded once at load
  from Fibonacci codewords (every codeword self-checked at build time). Registered in
  the catalog; opt-in (kept out of Fortress by default because pooling many codeword
  strings ahead of the string-encryption steps bloats the payload).
- **More, clearer error codes** (`src/steps/anti/anti-tamper.lua`,
  `docs/ERROR_CODES.md`): the coded aborts were expanded and regrouped into three
  developer-facing classes (hostile host / modified runtime / payload-build) with
  actionable guidance, while still not naming the exact internal check. The tested
  codes (`0x7A31`, `0x5C08`, `0x3E9D`) are preserved.

Verified: full suite green -- reg_vm_differential 60/60, reg_vm_superop_differential
13/13, reg_vm_encrypt 9/9 (incl. ChaCha20 RFC 8439 KAT), reg_vm_tamper 4/4,
reg_vm_fibonacci 10/10, fibonacci 10016, numeric_fibonacci 16/16, run 9/9,
differential 6/6, vm_coverage 29/29, adversarial 7/7, security 254/254, fuzz 365/365,
Luau smoke green. All presets run identically on the local Luau build, with no
`load`/`loadstring` invocation.