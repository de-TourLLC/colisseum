# Luau Backend Integration Plan

Status: planned integration only. The current Colisseum tree does not link or
build the official Luau implementation. This document defines the revision and
operational boundary to use if a native Luau compiler/runtime backend is added.

## Pinned Upstream

Use the official repository:

- Project: https://github.com/luau-lang/luau
- Pinned commit: `caee04d82d014ed104dd63edec1710fb6ab5794c`
- Commit URL: https://github.com/luau-lang/luau/commit/caee04d82d014ed104dd63edec1710fb6ab5794c
- Commit date observed: 2026-08-28
- Branch policy: do not build from `master`, a moving release branch, or an
  unverified binary. Fetch the commit by its full SHA and record the source
  archive checksum in the release build manifest.

The compiler and VM must always come from the same pinned Luau revision and
compatible build configuration. A change of revision is a backend compatibility
change and requires rebuilding both sides and rerunning the conformance suite.

## Integration Shape

The planned native backend has two deliberately separate parts:

1. An offline compiler component using `Luau.Compiler` (and its public
   `Luau.Ast` and `Luau.Bytecode` dependencies) to translate source text into
   Luau bytecode.
2. A runtime component using `Luau.VM` (and its runtime dependencies) to create
   a `lua_State`, load the resulting bytecode, and execute it.

The official CMake project validates this separation: runtime targets must not
depend on offline compiler or analysis targets. Production runtime packages
should therefore omit the compiler when bytecode is produced during a trusted
build step. A development or conversion tool may include both.

The public flow is the equivalent of:

```cpp
size_t bytecodeSize = 0;
char* bytecode = luau_compile(source, sourceSize, &options, &bytecodeSize);
int status = luau_load(state, chunkName, bytecode, bytecodeSize, 0);
free(bytecode);
```

The adapter must check the result of `luau_compile` and `luau_load`, preserve
diagnostic text, and free the compiler-owned byte buffer. It must not treat
compiled bytecode as source text or pass bytecode produced by another Luau
revision into the pinned VM.

Compiler defaults should be explicit in the adapter rather than inherited from
an uninitialized options structure. The initial profile is optimization level
1, debug level 1, type information level 0, coverage level 0, and the default
Luau vector configuration. Any change to optimization, debug, type-info,
coverage, vector precision, mutable globals, or known-library callbacks must be
versioned and tested as a backend profile change.

## Build Requirements

Requirements stated by the pinned repository's README and CMake files:

- CMake 3.10 or newer; use a separate out-of-tree build directory.
- C++17 for compiler, AST, bytecode, and related libraries.
- C++11 is sufficient for the VM library, although one C++17 toolchain for the
  complete integration is the preferred baseline.
- Supported baseline toolchains listed upstream include Microsoft Visual Studio
  2017 or newer, GCC 7 or newer, and Clang 7 or newer.
- No external runtime library dependency is required beyond the STL/CRT.
  Upstream test builds use doctest, and the REPL uses isocline; neither is a
  production backend requirement.

Recommended reproducible configuration:

```sh
cmake -S luau -B build/luau -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DLUAU_BUILD_CLI=OFF -DLUAU_BUILD_TESTS=ON
cmake --build build/luau --config RelWithDebInfo
```

On multi-configuration generators, always pass `--config RelWithDebInfo` to
the build and test commands. Keep compiler and VM static/shared-library mode,
CRT choice, exception/ABI settings, and Luau compile definitions consistent.
If a shared library is selected, upstream requires `LUAU_EXTERN_C=ON`.

Before accepting a backend build, run the upstream `Luau.UnitTest` and
`Luau.Conformance` targets, then run Colisseum's dialect-specific fixtures
against the exact VM artifact that will be distributed. Do not use a successful
library link as evidence of bytecode or language compatibility.

## Licensing and Notices

The official Luau repository states that the implementation is licensed under
the MIT License. The authoritative text at the pinned revision is:

- https://raw.githubusercontent.com/luau-lang/luau/caee04d82d014ed104dd63edec1710fb6ab5794c/LICENSE.txt

The repository also identifies its Lua 5.x-derived portions and supplies a
separate MIT notice:

- https://raw.githubusercontent.com/luau-lang/luau/c2ec0d4e5ca50796ba174a7565298f59aa572268/lua_LICENSE.txt

The Luau license requires retaining the applicable copyright and permission
notices in copies or substantial portions. It also asks integrators to include
Luau attribution in user-facing product documentation; attribution using the
Luau logo is encouraged where reasonable. Preserve both upstream license files
and relevant source notices in any source or binary distribution containing
Luau material, and add an attribution entry to the final product notices when
the integration is actually shipped.

Luau is permissively licensed, but that does not by itself resolve the license
obligations for a combined Colisseum distribution. Colisseum is AGPL-3.0, so a
real integration must receive a separate license review covering static versus
dynamic linking, modified Luau source, corresponding source, notices, and any
other bundled dependencies before distribution. This document is not a legal
opinion and does not grant trademark rights.

## Runtime Limitations

- Luau is a Lua 5.1-derived language, not a drop-in promise of compatibility
  with every Lua or Luau host. Test the exact dialect, compiler revision, VM,
  and host libraries together.
- Compilation is separate from loading. A VM-only deployment cannot compile
  source unless the compiler is also shipped or invoked elsewhere.
- Bytecode is an implementation artifact tied to the compatible Luau VM. Do not
  cache or distribute it as a stable cross-version format without validating
  the exact producer and consumer revision.
- The standard REPL is sandboxed and does not provide general filesystem access;
  `require` is the documented exception. An embedded host controls what
  libraries, module resolution, filesystem, network, and native functions are
  exposed. No host capability should be exposed by accident.
- Upstream recommends `luaL_sandbox` for the global state and
  `luaL_sandboxthread` for each script thread. This isolates script globals and
  protects built-in libraries from monkey-patching, but it is not a complete
  process or security boundary.
- The VM does not provide the Lua `__gc` behavior expected by some hosts. For
  userdata destruction, use Luau's `lua_newuserdatadtor` or the documented
  userdata-destructor APIs instead.
- Resource exhaustion remains possible through CPU, memory, recursion, stack,
  coroutine, or allocation pressure. Install host interruption/resource
  controls and execute untrusted output in an appropriately isolated process
  or sandbox with minimal capabilities.
- Luau output is executable code, not encryption or access control. Obfuscation
  does not prevent observation, debugging, or reconstruction by a party able to
  run the output.
- Native code generation, JIT-related behavior, debug information, and host
  callbacks can change performance and observability. They are outside the
  initial backend contract unless explicitly enabled and covered by tests.

## Acceptance Gate

An implementation may be considered integrated only when it has a checked-out
full-SHA source copy, reproducible compiler and VM artifacts, upstream tests,
Colisseum compatibility fixtures, documented host capabilities and limits, and
the required Luau/Lua notices. Any upstream revision, toolchain, bytecode
profile, or exposed library change reopens this gate.

## Primary References

- Luau README at the pinned revision: https://raw.githubusercontent.com/luau-lang/luau/c2ec0d4e5ca50796ba174a7565298f59aa572268/README.md
- Luau CMake configuration at the pinned revision: https://raw.githubusercontent.com/luau-lang/luau/c2ec0d4e5ca50796ba174a7565298f59aa572268/CMakeLists.txt
- Luau compiler API: https://raw.githubusercontent.com/luau-lang/luau/c2ec0d4e5ca50796ba174a7565298f59aa572268/Compiler/include/luacode.h
- Luau VM API: https://raw.githubusercontent.com/luau-lang/luau/c2ec0d4e5ca50796ba174a7565298f59aa572268/VM/include/lua.h
