# Colisseum Update Log

Date: 2026-09-10

## Register VM Hardening + Opaque Errors + Comment Hygiene

A round of register-VM hardening (all per-build, semantics-preserving) plus a fix
for design commentary leaking into shipped output.

Changes:
- **Keystream-masked bytecode** (`src/core/reg-bytecode.lua`, `reg-runtime.lua`):
  the in-memory fog is no longer a short repeating-XOR key. Each byte is masked
  with a per-position keystream (repeating fog byte XOR a per-offset hash), keyed
  off the fog seed, so there is no small period to peel. Derived once at VM start;
  the hot loop only does a table lookup. Portable all-integer math, byte-for-byte
  round-trip.
- **Polymorphic opcodes** (`reg-runtime.lua`, `src/steps/security/register-vm.lua`):
  each operation gets several interchangeable raw codes chosen per instruction,
  folded back by a per-build normalization table (`program.o`). The emitted stream
  has no 1:1 opcode mapping. Backward-compatible (dev path sets no `program.o`).
- **Superoperators** (`reg-bytecode.lua` `fuse` + `reg-runtime.lua` handlers +
  `register-vm.lua` wiring): a peephole fuses adjacent straight-line pairs
  (MOVE;MOVE, LOADK;LOADK, GETGLOBAL;GETGLOBAL) into single opcodes; the second
  slot is kept as a jump-target fallback, so no jump-offset rewriting is needed.
  New acceptance test `tests/reg_vm_superop_differential.lua` (13/13).
- **Silent anti-hook honeypot** (`reg-runtime.lua`): the in-loop sampler no longer
  throws the branded `0x2175` fingerprint; on tamper it latches a drift so
  arithmetic results become wrong. Clean runs are bit-for-bit unaffected.
- **Opaque coded errors** (`src/steps/anti/anti-tamper.lua`, `runtime-integrity.lua`,
  `docs/ERROR_CODES.md`): anti-tamper now selects among 9 codes by cause and
  runtime-integrity among 3, non-injectively (several causes share a code). The
  tested `0x7A31`/`0x5C08` codes are preserved. `ERROR_CODES.md` rewritten to be
  deliberately non-descriptive.
- **Guard comment stripping**: `anti-tamper` and `runtime-integrity` now strip
  their guard's comments before emission (blanking preserves line boundaries, so
  the beautify detector is unaffected). Previously, in text presets where `minify`
  runs before the guard, the entire commented template shipped verbatim. Repo
  comments across the tree were also trimmed to short headers + small notes.

Verified: full suite green -- reg_vm_differential 60/60, reg_vm_superop_differential
13/13, run 9/9, differential 6/6, vm_coverage 29/29, adversarial 7/7, security
254/254, fuzz 365/365. All 7 presets produce output identical to reference on the
local Luau build, with no `load`/`loadstring` invocation.