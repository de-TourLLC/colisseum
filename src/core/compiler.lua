-- Source compiler for the safe CLBC container.  This module only transforms
-- data; it never evaluates source text.
local Lexer = require("src.core.lexer")
local Parser = require("src.core.parser")
local Ast = require("src.core.ast")
local References = require("src.core.references")
local Bytecode = require("src.core.bytecode")
local Runtime = require("src.core.runtime")

local Compiler = {}

local unsupported = {
    ["continue"] = true, ["goto"] = true,
    ["::"] = true,
    ["&"] = true, ["|"] = true, ["~"] = true,
    ["<<"] = true, [">>"] = true, ["//="] = true
}
local expression_context = {
    ["return"] = true, ["="] = true, [","] = true,
    ["("] = true, ["["] = true, ["+"] = true, ["-"] = true,
    ["*"] = true, ["/"] = true, [".."] = true, ["and"] = true,
    ["or"] = true
}

local function diagnostic(kind, message, position)
    error("compiler: " .. kind .. " at " .. tostring(position or "eof") .. ": " .. message, 3)
end

local function token_text(token)
    return token and ("'" .. tostring(token.value) .. "'") or "end of input"
end

local function preflight(source)
    local tokens = Lexer.scan(source)
    local code = {}
    for _, token in ipairs(tokens) do
        if token.kind ~= "comment" then code[#code + 1] = token end
    end

    local blocks = {}
    local awaiting_do = false
    local function open(token, kind) blocks[#blocks + 1] = { kind = kind, token = token } end
    local function close(token, kind)
        local current = blocks[#blocks]
        if not current or current.kind ~= kind then
            diagnostic("malformed input", "unexpected " .. token_text(token), token and token.start)
        end
        blocks[#blocks] = nil
    end

    for index, token in ipairs(code) do
        if unsupported[token.value] then
            diagnostic("unsupported-syntax", "token " .. token_text(token) .. " is not supported", token.start)
        end
        if token.kind == "string" then
            local first, last = token.value:sub(1, 1), token.value:sub(-1)
            local long = token.value:match("^%[(=*)%[")
            if (long and last ~= "]") or (not long and (first ~= "'" and first ~= '"' or last ~= first)) then
                diagnostic("malformed input", "unterminated string", token.start)
            end
        elseif token.kind == "number" and not tonumber(token.value) then
            diagnostic("malformed input", "invalid number " .. token_text(token), token.start)
        elseif token.value == "function" then
            open(token, "end")
        elseif token.value == "for" then
            open(token, "end")
            awaiting_do = true
        elseif token.value == "while" then
            open(token, "end")
            awaiting_do = true
        elseif token.value == "if" then
            open(token, "end")
        elseif token.value == "do" then
            if awaiting_do then awaiting_do = false else open(token, "end") end
        elseif token.value == "repeat" then
            open(token, "until")
        elseif token.value == "end" then
            close(token, "end")
        elseif token.value == "until" then
            close(token, "until")
        end
    end
    if #blocks > 0 then
        diagnostic("malformed input", "unclosed " .. blocks[#blocks].kind, blocks[#blocks].token.start)
    end
end

local function parse(source)
    if type(source) ~= "string" then error("compiler: source must be a string", 2) end
    preflight(source)
    local ok, ast_or_error = pcall(Parser.parse, source)
    if not ok then
        local raw = tostring(ast_or_error)
        local position = raw:match("at%s+(%d+)")
        local message = raw:gsub("^.-:%s*", "")
        diagnostic("unsupported-syntax", message, position)
    end
    local ast = ast_or_error
    local valid, message = Ast.validate(ast)
    if not valid then error("compiler: invalid AST: " .. tostring(message), 2) end
    return ast
end

local function build(source)
    local ast = parse(source)
    local references = References.analyze(ast)
    local scopes, last_scope_id = Ast.assign_scope_ids(ast)
    local program = Bytecode.compile(ast)
    Bytecode.validate(program)
    return ast, scopes, references, program, last_scope_id
end

function Compiler.compile(source, options)
    if options ~= nil and type(options) ~= "table" then error("compiler: options must be a table", 2) end
    local ast, scopes, references, program, last_scope_id = build(source)
    local encoded = Bytecode.encode(program)
    if options and options.return_metadata then
        return encoded, {
            ast = ast, scopes = scopes, references = references,
            program = program, last_scope_id = last_scope_id
        }
    end
    return encoded
end

function Compiler.inspect(source)
    local ast, scopes, references, program, last_scope_id = build(source)
    local result = Runtime.inspect(program)
    result.ast = ast
    result.scopes = scopes
    result.references = references
    result.last_scope_id = last_scope_id
    result.bytecode = Bytecode.encode(program)
    return result
end

return Compiler
