-- Entry point for all bounded LuaJIT-compatible benchmarks.

require("benchmarks.presets")()
require("benchmarks.parser")()
require("benchmarks.bytecode")()
require("benchmarks.runtime")()
