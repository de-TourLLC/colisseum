# Colisseum Runtime Error Codes

Obfuscated output never reports failures in plain text. When a protection guard
fires at runtime, it aborts with a branded, deliberately opaque message:

```
ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: <CODE>
```

## The code is intentionally uninformative

The `<CODE>` does **not** identify which check fired or what was detected. This is
by design, and it is stronger than "the code is just opaque to outsiders":

- **The mapping is not descriptive.** Every code below means the same thing at the
  level anyone outside the project can act on: *a protection or integrity guard
  refused to continue.* Nothing in a code names the debug/executor/global/metatable/
  timing/nonce/hash/loader check behind it.
- **The mapping is not injective.** Several unrelated checks deliberately share one
  code, and one logical failure can surface under more than one code depending on
  which guard observed it first. So you cannot invert a code back to a cause even by
  collecting many samples.
- **The set is not stable across the whole surface.** Which code a given tampering
  attempt produces can depend on ordering and on the build. Two builds, or two
  environments, can answer the same probe with different codes.

The practical consequence: reading this page tells you *that* the program detected a
hostile or unsupported environment and stopped — never the internal reason. Turning a
code into the specific check requires deep familiarity with the engine internals; the
documentation intentionally does not provide that bridge.

## Known codes

All of the following are the same class of event — a guard tripped. They are listed
only so a legitimate user who hits one in a normal environment knows it is a Colisseum
protection abort (and can rebuild or report the code), not a bug in their own script.

| Code     | Class |
| -------- | ----------------------------- |
| `0x7A31` | Protection / integrity guard  |
| `0x5C08` | Protection / integrity guard  |
| `0x3E19` | Protection / integrity guard  |
| `0x6B0C` | Protection / integrity guard  |
| `0x41D7` | Protection / integrity guard  |
| `0x5D33` | Protection / integrity guard  |
| `0x2A88` | Protection / integrity guard  |
| `0x1F4E` | Protection / integrity guard  |
| `0x7C56` | Protection / integrity guard  |
| `0x0D91` | Protection / integrity guard  |
| `0x3E9D` | Payload / build integrity     |

The list is not exhaustive and may grow between builds.

## What to do if you see one

- **In the intended runtime** (a normal Roblox script / a plain Lua/Luau host, no
  debugger, no executor/injector, unmodified output): these guards score zero and
  never fire. If one fires anyway, the output is likely running on a runtime it was
  not built for, or the file was altered after the build — rebuild it and, if it
  persists, report the exact code.
- **Under a debugger, an executor/injector, or with the output edited by hand:** the
  abort is expected. That is the guard doing its job. No code-specific action exists
  or is intended.
