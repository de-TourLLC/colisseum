local Paths = {}

local groups = {
    noise = { "anti-deobfuscation", "boolean-noise", "field-index", "garbage-code", "junk-comments", "junk-functions", "opaque-predicates", "table-noise", "visual-noise" },
    anti = { "anti-tamper", "authenticated-strings", "coroutine-integrity-guard", "runtime-integrity" },
    analysis = { "complexity-guard", "comment-budget-analysis", "dialect-guard", "dynamic-feature-guard", "function-budget-analysis", "global-access-report", "identifier-collision-guard", "literal-budget-analysis", "line-length-analysis", "numeric-validity-validation", "operator-usage-report", "resource-budget-guard", "string-termination-validation", "unsupported-syntax-guard" },
    format = { "blank-line-collapse", "blank-line-policy", "comment-policy", "comment-preserving-line-normalize", "comma-layout", "delimiter-line-policy", "delimiter-normalize", "deterministic-formatting", "deterministic-layout", "final-newline-policy", "line-ending-normalize", "line-ending-policy", "newline-normalize", "operator-canonicalization", "operator-spacing-normalize", "protected-literal-formatting", "protected-token-spacing", "semicolon-normalize", "semicolon-policy", "tab-indent-normalize", "trailing-whitespace", "whitespace-normalize" },
    literals = { "boolean-normalize", "constant-array", "decimal-padding", "literal-grouping", "literal-padding", "nil-normalize", "numeric-base-normalize", "numeric-canonicalization", "numbers", "quote-normalize", "split-strings", "string-byte-encoding", "strings" },
    security = { "crypto", "vm", "native-vm", "register-vm", "protection-notice" },
    naming = { "identifier-case-normalize", "rename" },
    shared = { "token-safe" }
}

local lookup = {}
for group, names in pairs(groups) do
    for _, name in ipairs(names) do lookup[name] = group end
end

function Paths.group(name)
    return lookup[name]
end

function Paths.module(name)
    return "src.steps." .. (lookup[name] and lookup[name] .. "." or "") .. name
end

return Paths
