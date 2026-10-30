-- Prueba de extremo a extremo para Fortress.
-- Parte 1: lógica básica (funciona en Lua y Luau).
local function add(a, b) return a + b end

local sum = 0
for i = 1, 10 do sum = sum + i end

local s = "hola" .. " " .. "mundo"

-- Parte 2: tabla + método + closure
local acc = { total = 0 }
function acc:bump(n) self.total = self.total + n end
acc:bump(5)
acc:bump(7)

local function counter()
  local c = 0
  return function() c = c + 1; return c end
end
local nextc = counter()
nextc(); nextc()

-- Parte 3: aritmética con operador sobrecargado (como Vector3/CFrame en Roblox).
-- Stub local para poder ejecutar el output con luajit.
local VMeta = {}
VMeta.__index = VMeta
VMeta.__add = function(a, b)
  if getmetatable(a) ~= VMeta or getmetatable(b) ~= VMeta then
    error("arithmetic on Vector and number")
  end
  return setmetatable({ x = a.x + b.x }, VMeta)
end
local function V(x) return setmetatable({ x = x }, VMeta) end

local vec = V(1) + V(2) -- <-- esto es lo que revienta con el bug +hp del register VM

print("sum", sum)
print("string", s, #s)
print("acc.total", acc.total)
print("counter", nextc())
print("vector.x", vec.x)

return sum, s, acc.total, vec.x
