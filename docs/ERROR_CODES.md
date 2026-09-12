# Colisseum Runtime Error Codes

Obfuscated output never prints a plain-text failure. When a protection guard fires
at runtime, it aborts with a branded, coded message:

```
ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x<CODE>
```

This page is written for the **developer shipping the obfuscated script**. It tells
you enough to diagnose and fix a code you hit in your own testing, without turning
the codes into a step-by-step map of the internal checks for someone attacking the
output. Each code belongs to one of three **classes**; the class is what you act on.

## The three classes

Read the first hex digits as a rough family. Within a class, several distinct checks
share a code on purpose, so a code tells you the *kind* of problem, not the exact
line that caught it.

### 1. Hostile host — the runtime itself looks like an analysis environment

| Code | Typically means |
| ---- | --------------- |
| `0x3E19` | A debug hook is installed. |
| `0x3E44` | The debug API was replaced/wrapped. |
| `0x6B0C` | Executor/injector functions are present in the environment. |
| `0x6B77` | A known executor/injector marker was found. |
| `0x7C56` | A code loader (`load`/`loadstring`/`require`/…) was swapped. |
| `0x0D91` | Per-operation instrumentation (a tracing/timing hook) was detected. |

**What to do:** run the output in the environment you built it for — a normal Roblox
script or a plain Lua/Luau host, with no debugger attached and no exploit executor
loaded. If you are *intentionally* debugging or running under an executor, the abort
is expected and correct; test on a clean host instead.

### 2. Modified runtime — core functions, tables, or the output were changed

| Code | Typically means |
| ---- | --------------- |
| `0x7A31` | A guard's own baked self-check did not match (internal integrity). |
| `0x9C12` | The output was reformatted (a beautifier split its one line). |
| `0x41D7` / `0x41A2` | One or more core globals were replaced. |
| `0x58E0` | The script environment (`_ENV`/`_G`) diverged from the captured one. |
| `0x5D33` | Core functions are no longer native (wrapped in Lua). |
| `0x2A88` / `0x2AF1` | A `string`/`table`/`math` function was hooked or replaced. |
| `0x1F4E` / `0x1FB9` | A string or global metatable was swapped/intercepted. |

**What to do:** ship the file **exactly as Colisseum produced it** — do not run it
through a formatter/beautifier, and do not hand-edit it. Make sure nothing in your
game replaces standard globals or installs `hookfunction`/metatable hooks before your
script runs. If you legitimately need custom globals, load them *after* the script.

### 3. Payload / build integrity — the bytes no longer match the build

| Code | Typically means |
| ---- | --------------- |
| `0x5C08` | A guard's embedded expected digest did not verify. |
| `0x3E9D` | The encrypted payload failed its integrity check on load. |

**What to do:** the file was altered after it was built, or a byte was corrupted in
transit. Re-obfuscate from source and re-deploy the fresh output. If a clean rebuild
still aborts on a clean host, that is worth reporting (see below).

## Quick triage

- **You see a code while testing on a clean, intended runtime and unmodified output.**
  That should not happen — the guards score zero on a healthy host. Rebuild once; if it
  persists, report it (steps below), because it may be a real bug.
- **You see a code under a debugger, an executor, a beautified/edited file, or with
  global hooks installed.** Working as intended — remove that condition and retry.

## Reporting a code

If you believe a code fired wrongly, include: the exact code, the preset used, the
target (`--LuaU`/Lua), the runtime (Roblox / LuaJIT / Lua version), and whether the
output was edited after building. That is enough to reproduce without exposing the
script itself.

## Notes

- The codes above are the ones that can actually **abort** a run. The bundle also
  contains additional branded codes on paths that never execute; they exist to blur
  static analysis and will not surface at runtime.
- The register-VM backend (`Fortress`) does not always abort loudly: on some tamper
  signals it diverts to a silently wrong result instead of raising a code, so a clean
  code list is not a guarantee that a modified host will run correctly.
- The set may grow between versions; new codes stay within the three classes above.
