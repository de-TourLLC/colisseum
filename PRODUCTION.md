# Production Boundaries

Colisseum is a Lua/Luau source obfuscator under active development. This document
states what it does and does not guarantee, and what to check before shipping.

## What obfuscation is (and is not)

- Obfuscation raises the cost of reading, analyzing, and reverse-engineering the
  output. It is **not** encryption, **not** access control, and **not** a
  guarantee of irreversibility. Anyone who can run an output can, with enough
  effort, observe or reconstruct its behavior.
- Do **not** put secrets, keys, credentials, or personal data in code you
  distribute. The transformations do not protect them.
- The anti-tamper and integrity guards detect common tampering and hostile
  execution environments (debug hooks, replaced globals, executors/injectors).
  They are a deterrent, not a security boundary, and can be bypassed.

## Runtime behaviour

- Every build is unique (independent identifiers, values, layout) unless an
  explicit `seed` is supplied for a reproducible build.
- Output is emitted on a single physical line.
- Heavy decode loops yield cooperatively (`task.wait`) on Roblox, so large scripts
  do not trip the execution-time watchdog. Startup cost scales with payload size;
  `Full`/`Total` produce larger output than `Easy`/`Medium`/`Hard`.
- Runtime failures surface as branded, coded errors — see
  [docs/ERROR_CODES.md](docs/ERROR_CODES.md).

## Before you ship

1. Pin a Colisseum revision and keep `LICENSE.md` (AGPL-3.0) plus applicable
   notices from `THIRD_PARTY_NOTICES.md`.
2. Test the output on the **same dialect and runtime version** as the target
   (Lua and Luau are not interchangeable by default). Confirm it loads and runs.
3. Run it only in an isolated environment with least privilege while validating.
4. Review the output for any secrets or excessive permissions before publishing.

## Liability

The project is provided without warranty under its AGPL-3.0 license and its
security policy. Whoever runs, distributes, or publishes an output retains
responsibility for their own testing, permissions, legal compliance, and security
controls.
