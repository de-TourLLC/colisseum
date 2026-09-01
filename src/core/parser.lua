local Lexer = require("src.core.lexer")

local Parser = {}

local precedence = {
    ["or"] = 1, ["and"] = 2, ["<"] = 3, [">"] = 3, ["<="] = 3,
    [">="] = 3, ["=="] = 3, ["~="] = 3, [".."] = 4, ["+"] = 5,
    ["-"] = 5, ["*"] = 6, ["/"] = 6, ["//"] = 6, ["%"] = 6,
    ["^"] = 7
}

-- Luau compound assignment operators; each desugars to `t = t <op> e`.
local compound_assign = {
    ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true,
    ["%="] = true, ["^="] = true, ["..="] = true,
}

local function parser(tokens)
    local object = { tokens = tokens, index = 1 }

    function object:peek()
        return self.tokens[self.index]
    end

    function object:take(value)
        local token = self:peek()
        if token and (not value or token.value == value) then
            self.index = self.index + 1
            return token
        end
    end

    function object:expect(value)
        local token = self:take(value)
        if not token then
            local current = self:peek()
            error("parser: expected '" .. value .. "' at " .. (current and current.start or "eof"))
        end
        return token
    end

    -- Skip a Luau generic parameter list `<T, U..., V = W>` after a function name
    -- (type-level only; erased semantically). Handles nested `<...>` and `>>`.
    function object:skip_generics()
        if not (self:peek() and self:peek().value == "<") then return end
        local depth = 0
        while self:peek() do
            local v = self:take().value
            if v == "<" then depth = depth + 1
            elseif v == ">" then depth = depth - 1; if depth <= 0 then return end
            elseif v == ">>" then depth = depth - 2; if depth <= 0 then return end end
        end
    end

    function object:primary()
        local token = self:peek()
        if not token then error("parser: unexpected end of input") end
        if token.value == "(" then
            self:take()
            local value = self:expression(0)
            self:expect(")")
            return { kind = "group", value = value, start = token.start, finish = value.finish }
        end
        if token.value == "{" then
            self:take()
            local values = {}
            if not self:take("}") then
                while true do
                    local key = self:peek()
                    if key and key.value == "[" then
                        -- computed key: [expr] = value
                        self:take()
                        local keyexpr = self:expression(0)
                        self:expect("]")
                        self:expect("=")
                        local value = self:expression(0)
                        values[#values + 1] = { kind = "keyfield", key = keyexpr, value = value, start = key.start, finish = value.finish }
                    elseif key and key.kind == "identifier" and self.tokens[self.index + 1] and self.tokens[self.index + 1].value == "=" then
                        self:take()
                        self:take("=")
                        values[#values + 1] = { kind = "field", key = key.value, value = self:expression(0), start = key.start }
                    else
                        values[#values + 1] = self:expression(0)
                    end
                    -- Fields separate on ',' or ';' (interchangeable), and a trailing
                    -- separator before '}' is allowed.
                    if not (self:take(",") or self:take(";")) then break end
                    if self:peek() and self:peek().value == "}" then break end
                end
                self:expect("}")
            end
            return { kind = "table", values = values, start = token.start, finish = (self.tokens[self.index - 1]).finish }
        end
        if token.kind == "number" then self:take(); return { kind = "number", value = token.value, start = token.start, finish = token.finish } end
        if token.kind == "string" then self:take(); return { kind = "string", value = token.value, start = token.start, finish = token.finish } end
        if token.value == "..." then
            self:take()
            return { kind = "vararg", start = token.start, finish = token.finish }
        end
        if token.value == "function" then
            -- Anonymous function expression: function(params) body end
            self:take()
            self:skip_generics()
            self:expect("(")
            local parameters = {}
            if not self:take(")") then
                repeat
                    local parameter = self:take()
                    if not parameter or (parameter.kind ~= "identifier" and parameter.value ~= "...") then
                        error("parser: expected parameter at " .. token.start)
                    end
                    parameters[#parameters + 1] = parameter.value
                until not self:take(",")
                self:expect(")")
            end
            local body = self:block({ end_ = true })
            local finish = self:expect("end")
            return { kind = "function", name = "", local_function = false, parameters = parameters, body = body, start = token.start, finish = finish.finish }
        end
        if token.kind == "identifier" then
            self:take()
            if token.value == "true" or token.value == "false" or token.value == "nil" then
                return { kind = "literal", value = token.value, start = token.start, finish = token.finish }
            end
            return { kind = "identifier", value = token.value, start = token.start, finish = token.finish }
        end
        error("parser: unexpected token at " .. token.start)
    end

    function object:postfix(value)
        while true do
            local token = self:peek()
            if not token then return value end
            if token.value == "." or token.value == ":" then
                self:take()
                local name = self:take()
                if not name or name.kind ~= "identifier" then error("parser: expected member name at " .. token.start) end
                value = { kind = "member", object = value, name = name.value, method = token.value == ":", start = value.start, finish = name.finish }
            elseif token.value == "[" then
                self:take()
                local key = self:expression(0)
                local close = self:expect("]")
                value = { kind = "index", object = value, key = key, start = value.start, finish = close.finish }
            elseif token.value == "(" then
                self:take()
                local arguments = {}
                if not self:take(")") then
                    repeat
                        arguments[#arguments + 1] = self:expression(0)
                    until not self:take(",")
                    self:expect(")")
                end
                value = { kind = "call", callee = value, arguments = arguments, start = value.start, finish = (self.tokens[self.index - 1] or token).finish }
            else
                return value
            end
        end
    end

    function object:expression(minimum)
        local token = self:peek()
        local left
        if token and (token.value == "not" or token.value == "-" or token.value == "#") then
            self:take()
            local value = { kind = "unary", operator = token.value, value = self:expression(7), start = token.start }
            value.finish = value.value.finish
            left = value
        else
            left = self:postfix(self:primary())
        end
        while true do
            local operator = self:peek()
            local level = operator and precedence[operator.value]
            if not level or level < minimum then break end
            self:take()
            local right = self:expression(level + (operator.value == "^" and 0 or 1))
            left = { kind = "binary", operator = operator.value, left = left, right = right, start = left.start, finish = right.finish }
        end
        return left
    end

    function object:statement()
        local token = self:peek()
        if not token then return nil end
        if token.value == "break" then
            self:take()
            return { kind = "break", start = token.start, finish = token.finish }
        end
        if token.value == "function" or (token.value == "local" and self.tokens[self.index + 1] and self.tokens[self.index + 1].value == "function") then
            local local_function = token.value == "local"
            if local_function then self:take("local") end
            self:expect("function")
            local name = self:take()
            if not name or name.kind ~= "identifier" then error("parser: expected function name at " .. token.start) end
            -- Dotted / method definitions: `function a.b.c(...)` and `function a:m(...)`.
            -- Only for non-local `function`; desugar to an assignment of an anonymous
            -- function to the member path (methods gain an implicit `self` parameter),
            -- reusing the existing assign/member/function nodes.
            local next_value = self:peek() and self:peek().value
            if not local_function and (next_value == "." or next_value == ":") then
                local target = { kind = "identifier", value = name.value, start = name.start, finish = name.finish }
                local is_method = false
                while true do
                    local separator = self:peek()
                    if not separator or (separator.value ~= "." and separator.value ~= ":") then break end
                    self:take()
                    local key = self:take()
                    if not key or key.kind ~= "identifier" then error("parser: expected member name at " .. separator.start) end
                    target = { kind = "member", object = target, name = key.value, method = false, start = target.start, finish = key.finish }
                    if separator.value == ":" then is_method = true; break end
                end
                self:skip_generics()
                self:expect("(")
                local parameters = {}
                if is_method then parameters[1] = "self" end
                if not self:take(")") then
                    repeat
                        local parameter = self:take()
                        if not parameter or (parameter.kind ~= "identifier" and parameter.value ~= "...") then
                            error("parser: expected parameter at " .. token.start)
                        end
                        parameters[#parameters + 1] = parameter.value
                    until not self:take(",")
                    self:expect(")")
                end
                local body = self:block({ end_ = true })
                local finish = self:expect("end")
                local closure = { kind = "function", name = "", local_function = false, parameters = parameters, body = body, start = token.start, finish = finish.finish }
                return { kind = "assign", target = target, value = closure, start = token.start, finish = finish.finish }
            end
            self:skip_generics()
            self:expect("(")
            local parameters = {}
            if not self:take(")") then
                repeat
                    local parameter = self:take()
                    if not parameter or (parameter.kind ~= "identifier" and parameter.value ~= "...") then
                        error("parser: expected parameter at " .. token.start)
                    end
                    parameters[#parameters + 1] = parameter.value
                until not self:take(",")
                self:expect(")")
            end
            local body = self:block({ end_ = true })
            local finish = self:expect("end")
            return { kind = "function", name = name.value, local_function = local_function, parameters = parameters, body = body, start = token.start, finish = finish.finish }
        elseif token.value == "for" then
            self:take()
            local names = {}
            repeat
                local name = self:take()
                if not name or name.kind ~= "identifier" then error("parser: expected for variable at " .. token.start) end
                names[#names + 1] = name.value
            until not self:take(",")
            if self:take("=") then
                local initial = self:expression(0)
                self:expect(",")
                local limit = self:expression(0)
                local step
                if self:take(",") then step = self:expression(0) end
                self:expect("do")
                local body = self:block({ end_ = true })
                local finish = self:expect("end")
                return { kind = "for", name = names[1], initial = initial, limit = limit, step = step, body = body, start = token.start, finish = finish.finish }
            end
            self:expect("in")
            local exprs = {}
            repeat exprs[#exprs + 1] = self:expression(0) until not self:take(",")
            self:expect("do")
            local body = self:block({ end_ = true })
            local finish = self:expect("end")
            return { kind = "forin", names = names, exprs = exprs, body = body, start = token.start, finish = finish.finish }
        elseif token.value == "repeat" then
            self:take()
            local body = self:block({ until_ = true })
            self:expect("until")
            local condition = self:expression(0)
            return { kind = "repeat", body = body, condition = condition, start = token.start, finish = condition.finish }
        end
        if token.value == "if" then
            self:take()
            local condition = self:expression(0)
            self:expect("then")
            local branches = { { condition = condition, body = self:block({ elseif_ = true, else_ = true, end_ = true }) } }
            while self:take("elseif") do
                local branch_condition = self:expression(0)
                self:expect("then")
                branches[#branches + 1] = { condition = branch_condition, body = self:block({ elseif_ = true, else_ = true, end_ = true }) }
            end
            local fallback
            if self:take("else") then fallback = self:block({ end_ = true }) end
            local finish = self:expect("end")
            return { kind = "if", branches = branches, fallback = fallback, start = token.start, finish = finish.finish }
        elseif token.value == "while" then
            self:take()
            local condition = self:expression(0)
            self:expect("do")
            local body = self:block({ end_ = true })
            local finish = self:expect("end")
            return { kind = "while", condition = condition, body = body, start = token.start, finish = finish.finish }
        elseif token.value == "do" then
            self:take()
            local body = self:block({ end_ = true })
            local finish = self:expect("end")
            return { kind = "do", body = body, start = token.start, finish = finish.finish }
        end
        if token.value == "local" then
            self:take()
            local names = {}
            repeat
                local name = self:take()
                if not name or name.kind ~= "identifier" then error("parser: expected local name at " .. token.start) end
                names[#names + 1] = name.value
            until not self:take(",")
            local values = {}
            if self:take("=") then
                repeat values[#values + 1] = self:expression(0) until not self:take(",") end
            return { kind = "local", names = names, values = values, start = token.start, finish = (self.tokens[self.index - 1] or token).finish }
        elseif token.value == "return" then
            self:take()
            local values = {}
            local next_token = self:peek()
            if next_token and next_token.value ~= "end" then
                repeat values[#values + 1] = self:expression(0) until not self:take(",") end
            return { kind = "return", values = values, start = token.start, finish = (self.tokens[self.index - 1] or token).finish }
        end
        local value = self:expression(0)
        local peeked = self:peek()
        if peeked and compound_assign[peeked.value] then
            -- Luau compound assignment `t <op>= e` desugars to `t = t <op> e`.
            self:take()
            local rhs = self:expression(0)
            local operator = peeked.value:sub(1, #peeked.value - 1)
            local combined = { kind = "binary", operator = operator, left = value, right = rhs, start = value.start, finish = rhs.finish }
            return { kind = "assign", target = value, value = combined, start = value.start, finish = rhs.finish }
        end
        if self:peek() and self:peek().value == "," then
            -- multiple assignment: t1, t2, ... = v1, v2, ...
            local targets = { value }
            while self:take(",") do targets[#targets + 1] = self:expression(0) end
            self:expect("=")
            local values = { self:expression(0) }
            while self:take(",") do values[#values + 1] = self:expression(0) end
            return { kind = "massign", targets = targets, values = values, start = value.start, finish = (self.tokens[self.index - 1]).finish }
        elseif self:take("=") then
            return { kind = "assign", target = value, value = self:expression(0), start = value.start, finish = (self.tokens[self.index - 1]).finish }
        end
        return { kind = "expression", value = value, start = value.start, finish = value.finish }
    end

    function object:block(stop)
        local body = {}
        while self:peek() do
            local value = self:peek().value
            if (stop.elseif_ and value == "elseif") or (stop.else_ and value == "else") or
                (stop.end_ and value == "end") or (stop.until_ and value == "until") then break end
            if value == ";" then
                self:take() -- empty statement / optional statement separator
            else
                body[#body + 1] = self:statement()
            end
        end
        return body
    end

    function object:chunk()
        return { kind = "chunk", body = self:block({}) }
    end

    return object
end

function Parser.parse(source)
    local tokens = {}
    for _, token in ipairs(Lexer.scan(source)) do
        if token.kind ~= "comment" then tokens[#tokens + 1] = token end
    end
    return parser(tokens):chunk()
end

return Parser
