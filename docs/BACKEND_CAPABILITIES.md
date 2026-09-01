# Backend Capability Manifest

`src.core.backend-manifest` provides non-executing production discovery for the
optional Luau backend. `inspect({ compiler = path })` checks the pinned Luau and
Fiu submodules, verifies their expected revisions, validates the compiler path,
and returns `compile` and `package` capability states.

The module reads files and git metadata only. It does not load `Source.lua`, run
the compiler, execute source, or invoke a shell. A package is reported ready only
when the compiler path is present, Luau is at the pinned revision, and Fiu
exposes its required API markers. A missing compiler produces `unavailable`,
while a configured compiler plus pinned Luau produces `compile-ready`.
