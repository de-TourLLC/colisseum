local Parser = require("src.core.parser")
local Validate = require("src.core.validate")

local Step = { name = "identifier-collision-guard", version = 1 }
Step.metadata = {
    id = Step.name, version = Step.version, kind = "validation",
    description = "Detects duplicate declarations in the same lexical scope before transformations run."
}

local function check_body(body, declarations)
    local names = {}
    for _, statement in ipairs(body) do
        if statement.kind == "local" then
            for _, name in ipairs(statement.names) do
                if names[name] then error("identifier-collision-guard: duplicate declaration '" .. name .. "' at " .. statement.start) end
                names[name] = true; declarations = declarations + 1
            end
        elseif statement.kind == "function" then
            if names[statement.name] then error("identifier-collision-guard: duplicate declaration '" .. statement.name .. "' at " .. statement.start) end
            names[statement.name] = true; declarations = declarations + 1
            local parameters = {}; for _, name in ipairs(statement.parameters) do
                if parameters[name] then error("identifier-collision-guard: duplicate parameter '" .. name .. "' at " .. statement.start) end
                parameters[name] = true; declarations = declarations + 1
            end
            declarations = check_body(statement.body, declarations)
        elseif statement.kind == "if" then
            for _, branch in ipairs(statement.branches) do declarations = check_body(branch.body, declarations) end
            if statement.fallback then declarations = check_body(statement.fallback, declarations) end
        elseif statement.kind == "while" or statement.kind == "do" or statement.kind == "repeat" then
            declarations = check_body(statement.body, declarations)
        elseif statement.kind == "for" then
            declarations = declarations + 1; declarations = check_body(statement.body, declarations)
        end
    end
    return declarations
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("identifier-collision-guard: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("identifier-collision-guard: options must be a table") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error("identifier-collision-guard: invalid structure at " .. position .. ": " .. message) end
    local ok, ast = pcall(Parser.parse, source)
    if not ok then error("identifier-collision-guard: cannot analyze declarations: " .. tostring(ast)) end
    local declarations = check_body(ast.body, 0)
    Step.last_metadata = { declaration_count = declarations, collision_count = 0, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
