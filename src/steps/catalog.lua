local StepPaths = require("src.core.step-paths")
local catalog = {
    {
        id = "anti-tamper",
        module = "src.steps.anti-tamper",
        version = 4,
        description = "Adds runtime checks for tampering and hostile execution environments.",
        dependencies = { "crypto" }
    },
    {
        id = "blank-line-collapse",
        module = "src.steps.blank-line-collapse",
        version = 1,
        description = "Collapses surplus blank lines outside protected tokens.",
        dependencies = {}
    },
    {
        id = "crypto",
        module = "src.steps.crypto",
        version = 5,
        description = "Provides cryptographic helpers used by transformation steps.",
        dependencies = {}
    },
    {
        id = "comment-policy",
        module = "src.steps.comment-policy",
        version = 1,
        description = "Removes trailing horizontal whitespace before protected comments.",
        dependencies = {}
    },
    {
        id = "comma-layout",
        module = "src.steps.comma-layout",
        version = 1,
        description = "Uses deterministic spacing after same-line commas.",
        dependencies = {}
    },
    {
        id = "delimiter-line-policy",
        module = "src.steps.delimiter-line-policy",
        version = 1,
        description = "Removes horizontal padding next to delimiters.",
        dependencies = {}
    },
    {
        id = "deterministic-layout",
        module = "src.steps.deterministic-layout",
        version = 1,
        description = "Normalizes indentation to a deterministic width.",
        dependencies = {}
    },
    {
        id = "final-newline-policy",
        module = "src.steps.final-newline-policy",
        version = 1,
        description = "Ensures source ends with one configured newline.",
        dependencies = {}
    },
    {
        id = "literal-padding",
        module = "src.steps.literal-padding",
        version = 1,
        description = "Wraps literal values to make generated source less recognizable.",
        dependencies = {}
    },
    {
        id = "line-ending-normalize",
        module = "src.steps.line-ending-normalize",
        version = 1,
        description = "Normalizes source line endings without changing protected tokens.",
        dependencies = {}
    },
    {
        id = "line-ending-policy",
        module = "src.steps.line-ending-policy",
        version = 1,
        description = "Applies an explicit LF or CRLF policy to source gaps.",
        dependencies = {}
    },
    {
        id = "minify",
        module = "src.steps.minify",
        version = 2,
        description = "Removes comments and unnecessary whitespace from source code.",
        dependencies = {}
    },
    {
        id = "numbers",
        module = "src.steps.numbers",
        version = 2,
        description = "Transforms decimal number literals into equivalent expressions.",
        dependencies = {}
    },
    {
        id = "numeric-canonicalization",
        module = "src.steps.numeric-canonicalization",
        version = 1,
        description = "Canonicalizes decimal mantissas and exponents.",
        dependencies = {}
    },
    {
        id = "operator-canonicalization",
        module = "src.steps.operator-canonicalization",
        version = 1,
        description = "Uses deterministic spacing around binary operators.",
        dependencies = {}
    },
    {
        id = "protected-literal-formatting",
        module = "src.steps.protected-literal-formatting",
        version = 1,
        description = "Formats spacing around protected string literals.",
        dependencies = {}
    },
    {
        id = "quote-normalize",
        module = "src.steps.quote-normalize",
        version = 1,
        description = "Normalizes string quote styles when the literal can be preserved safely.",
        dependencies = {}
    },
    {
        id = "rename",
        module = "src.steps.rename",
        version = 3,
        description = "Renames local identifiers while preserving lexical references.",
        dependencies = {}
    },
    {
        id = "semicolon-normalize",
        module = "src.steps.semicolon-normalize",
        version = 1,
        description = "Replaces statement semicolons with line breaks.",
        dependencies = {}
    },
    {
        id = "strings",
        module = "src.steps.strings",
        version = 2,
        description = "Transforms string literals into runtime character constructions.",
        dependencies = {}
    },
    {
        id = "tab-indent-normalize",
        module = "src.steps.tab-indent-normalize",
        version = 1,
        description = "Expands tabs in unprotected source gaps.",
        dependencies = {}
    },
    {
        id = "trailing-whitespace",
        module = "src.steps.trailing-whitespace",
        version = 1,
        description = "Removes trailing whitespace outside protected tokens.",
        dependencies = {}
    },
    {
        id = "strip-comments",
        module = "src.steps.strip-comments",
        version = 1,
        description = "Replaces comments with whitespace while preserving line boundaries.",
        dependencies = {}
    },
    {
        id = "vm",
        module = "src.steps.vm",
        version = 4,
        description = "Wraps source in a keystream-decoded runtime instruction loop.",
        dependencies = {}
    },
    {
        id = "whitespace-normalize",
        module = "src.steps.whitespace-normalize",
        version = 1,
        description = "Normalizes insignificant whitespace without changing protected tokens.",
        dependencies = {}
    }
}

local extra = {
    { "anti-deobfuscation", "Adds bounded static tripwires without executing decoys.", 2 },
    { "protection-notice", "Embeds a configurable protection notice (base64, hidden) as a trailing comment.", 2 },
    { "authenticated-strings", "Adds bounded per-build string integrity metadata." },
    { "boolean-noise", "Rewrites booleans with side-effect-free equivalent expressions.", 2 },
    { "boolean-normalize", "Normalizes boolean literals safely." },
    { "blank-line-policy", "Applies a deterministic blank-line policy." },
    { "comment-budget-analysis", "Reports comment volume against a configured budget." },
    { "comment-preserving-line-normalize", "Normalizes lines while preserving comments." },
    { "complexity-guard", "Rejects source exceeding complexity limits." },
    { "dialect-guard", "Checks source structure and rejects syntax outside the selected Lua dialect." },
    { "line-length-analysis", "Validates source and enforces a maximum physical line length." },
    { "delimiter-normalize", "Normalizes safe delimiter spacing." },
    { "delimiter-validation", "Validates protected delimiter structures." },
    { "deterministic-formatting", "Applies deterministic formatting outside protected tokens." },
    { "decimal-padding", "Pads safe decimal literals without changing value." },
    { "dynamic-feature-guard", "Detects unsupported dynamic language features." },
    { "function-budget-analysis", "Reports function count against a configured budget." },
    { "global-access-report", "Reports unresolved global accesses." },
    { "identifier-case-normalize", "Normalizes safe generated identifier casing." },
    { "identifier-collision-guard", "Rejects unsafe identifier collisions." },
    { "literal-grouping", "Groups safe literal expressions." },
    { "literal-budget-analysis", "Reports literal volume against a configured budget." },
    { "newline-normalize", "Normalizes safe newline boundaries." },
    { "nil-normalize", "Normalizes nil literals safely." },
    { "numeric-base-normalize", "Normalizes safe numeric bases." },
    { "numeric-validity-validation", "Validates numeric literal spelling." },
    { "operator-spacing-normalize", "Normalizes operator spacing." },
    { "operator-usage-report", "Reports operator usage." },
    { "protected-token-spacing", "Normalizes spacing around protected tokens." },
    { "resource-budget-guard", "Rejects source exceeding resource budgets." },
    { "semicolon-policy", "Applies a deterministic semicolon policy." },
    { "string-byte-encoding", "Encodes safe string literals with a local decoder." },
    { "string-termination-validation", "Validates string termination." },
    { "garbage-code", "Adds bounded unreachable local statements.", 2 },
    { "opaque-predicates", "Inserts bounded dead blocks guarded by opaque always-false predicates." },
    { "control-flow-flatten", "Flattens top-level control flow into a shuffled state-machine dispatcher." },
    { "constant-array", "Pools string literals into a shuffled, keyed-encoded array with indexed access." },
    { "split-strings", "Splits string literals into concatenated pieces at random cut points." },
    { "junk-functions", "Adds bounded, never-called dead decoy functions." },
    { "junk-comments", "Sprinkles bounded random-glyph block comments between tokens." },
    { "field-index", "Rewrites dotted field access into bracket-indexed access with encoded keys.", 2 },
    { "runtime-integrity", "Prepends a runtime self-integrity and environment guard." },
    { "native-vm", "Compiles to ChaCha-encrypted native bytecode run by the embedded VM with per-build opcode randomization and KAT enum dispatch (Lua target, no loadstring).", 2 },
    { "register-vm", "Compiles to ChaCha-encrypted register bytecode run by the embedded register VM with per-build opcode permutation; 2-6x faster than the tree-walker, Lua + Luau, no loadstring." },
    { "table-noise", "Adds bounded unreachable table data.", 2 },
    { "visual-noise", "Adds bounded deterministic layout noise." },
    { "coroutine-integrity-guard", "Reports coroutine-sensitive runtime usage." },
    { "unsupported-syntax-guard", "Rejects unsupported syntax explicitly." }
}
for _, item in ipairs(extra) do
    catalog[#catalog + 1] = { id = item[1], module = "src.steps." .. item[1], version = item[3] or 1, description = item[2], dependencies = {} }
end
for _, item in ipairs(catalog) do item.module = StepPaths.module(item.id) end
return catalog
