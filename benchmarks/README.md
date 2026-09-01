# Benchmarks

Run from the repository root with:

```text
luajit benchmarks/run.lua
```

The benchmark suite uses one fixed, bounded fixture and finite iteration
counts. It reports CPU time from `os.clock()` and the Lua allocator delta from
`collectgarbage("count")`, when provided by the runtime. The preset benchmark
only transforms source text. The bytecode benchmark only compiles and decodes
CLBC. The restricted runtime benchmark calls `Runtime.run` with explicit
finite limits. No benchmark uses `load`, `loadstring`, or arbitrary input.
