# Colisseum Update Log

Date: 2026-09-01

## Post-VM Noise Round For The Register VM

Added a second, final layer of semantic junk ON TOP OF the sealed/encrypted register
VM output (the `fortress` preset / `--backend register`), so a deobfuscator that has
already unwound the VM is confronted with a fresh pile of meaningless statements that
assemble into nothing. Works purely by string injection at the top-level statement
boundaries of the finished bundle -- it never re-lexes the (large) encrypted payload
and never touches the compiler, decoder, interpreter, ChaCha seal, or guard ICONs.

Changes:
- `src/steps/security/register-vm.lua` now drains its own `|postvm` sub-seed
  (deterministic under an explicit build seed, divergent otherwise) and prepends a
  noise prologue before the `local B/R/C/P/E/V` loader chain:
  - 2-4 decoy functions that fold meaningless arithmetic (`... %9973`) and are
    never called.
  - 2-4 opaque always-false predicates (`a==b and N==N+k then return ... end`)
    guarding dead blocks; the guarded `return` is unreachable so execution always
    flows through to the real VM loader.
  - 1-2 "fake stages" that fold plain constants and final-discard the result
    (`sink = sink * 0`).
- Every injected identifier keeps the `coli_*` scheme, and the correctness-critical
  tail (`return V[1],V[2],V[3],V[4]`) is left byte-identical, so emitted programs run
  and return exactly the VM results.
- Only constructs the tree-walking register VM supports are emitted (locals, local
  function, numeric for, if/then/return/end, and/or/==/~=, + - * %, numeric
  literals, [] indexing); no bitwise ops and no builtins on the critical path.
- `tests/security.lua` gained the `package.path` bootstrap (via `debug.getinfo`) so
  it runs standalone, matching the other suites.

Verified: full suite green -- security 254/254 (incl. "fortress bundle executes on
the register VM and returns 42", seeded reproducibility, per-build divergence),
run 8/8, adversarial 7/7, differential 6/6, reg_vm_differential 60/60, fuzz 365/365.
No loadstring, no plaintext fragments leaked, single `coli_*` identifier family.