local TestFramework = {}
TestFramework.__index = TestFramework

export type TestCase = {
	name: string,
	fn: () -> (),
	skip: boolean?,
}

export type TestSuite = {
	name: string,
	tests: { TestCase },
}

export type TestResults = {
	passed: number,
	failed: number,
	skipped: number,
	total: number,
	success: boolean,
	durationSeconds: number,
}

function TestFramework.new()
	local self = setmetatable({}, TestFramework)
	self.suites = {} :: { TestSuite }
	return self
end

-- Define un grupo de tests relacionados (un "describe" al estilo Jest/TestEZ)
function TestFramework:describe(suiteName: string, callback: (suite: any) -> ())
	local suite: TestSuite = { name = suiteName, tests = {} }
	local suiteApi = {}

	function suiteApi.it(testName: string, fn: () -> ())
		table.insert(suite.tests, { name = testName, fn = fn, skip = false })
	end

	-- Permite marcar un test para saltearlo sin borrarlo (útil para casos pendientes)
	function suiteApi.xit(testName: string, fn: () -> ())
		table.insert(suite.tests, { name = testName, fn = fn, skip = true })
	end

	callback(suiteApi)
	table.insert(self.suites, suite)
end

-- Aserciones
local Assert = {}

function Assert.equal(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(
			string.format(
				"%s\n    esperado: %s\n    obtenido: %s",
				message or "assertEqual falló",
				tostring(expected),
				tostring(actual)
			),
			2
		)
	end
end

function Assert.notEqual(actual: any, expected: any, message: string?)
	if actual == expected then
		error(string.format("%s\n    no se esperaba: %s", message or "assertNotEqual falló", tostring(expected)), 2)
	end
end

-- Compara tablas por contenido (deep equal), no por referencia
function Assert.deepEqual(actual: any, expected: any, message: string?)
	local function deepCompare(a: any, b: any): boolean
		if type(a) ~= type(b) then
			return false
		end
		if type(a) ~= "table" then
			return a == b
		end
		for k, v in pairs(a) do
			if not deepCompare(v, (b :: any)[k]) then
				return false
			end
		end
		for k in pairs(b) do
			if (a :: any)[k] == nil and (b :: any)[k] ~= nil then
				return false
			end
		end
		return true
	end

	if not deepCompare(actual, expected) then
		error(
			string.format(
				"%s\n    esperado: %s\n    obtenido: %s",
				message or "assertDeepEqual falló",
				tostring(expected),
				tostring(actual)
			),
			2
		)
	end
end

function Assert.isTrue(value: any, message: string?)
	if value ~= true then
		error(string.format("%s (obtenido: %s)", message or "se esperaba true", tostring(value)), 2)
	end
end

function Assert.isFalse(value: any, message: string?)
	if value ~= false then
		error(string.format("%s (obtenido: %s)", message or "se esperaba false", tostring(value)), 2)
	end
end

function Assert.isNil(value: any, message: string?)
	if value ~= nil then
		error(string.format("%s (obtenido: %s)", message or "se esperaba nil", tostring(value)), 2)
	end
end

function Assert.isNotNil(value: any, message: string?)
	if value == nil then
		error(message or "se esperaba un valor no-nil", 2)
	end
end

function Assert.isType(value: any, expectedType: string, message: string?)
	if typeof(value) ~= expectedType then
		error(
			string.format(
				"%s\n    tipo esperado: %s\n    tipo obtenido: %s",
				message or "assertType falló",
				expectedType,
				typeof(value)
			),
			2
		)
	end
end

-- Compara números con tolerancia (para floats)
function Assert.near(actual: number, expected: number, tolerance: number?, message: string?)
	local tol = tolerance or 1e-6
	if math.abs(actual - expected) > tol then
		error(
			string.format(
				"%s\n    esperado ≈ %s (tolerancia %s)\n    obtenido: %s",
				message or "assertNear falló",
				tostring(expected),
				tostring(tol),
				tostring(actual)
			),
			2
		)
	end
end

-- Verifica que fn() lance un error. expectedMessage es opcional (substring a buscar).
function Assert.throws(fn: () -> (), expectedMessage: string?, message: string?)
	local ok, err = pcall(fn)
	if ok then
		error(message or "se esperaba que la función lanzara un error, pero no lo hizo", 2)
	end
	if expectedMessage and not tostring(err):find(expectedMessage, 1, true) then
		error(
			string.format(
				"%s\n    el error no contiene: %s\n    error real: %s",
				message or "assertThrows falló",
				expectedMessage,
				tostring(err)
			),
			2
		)
	end
end

function Assert.doesNotThrow(fn: () -> (), message: string?)
	local ok, err = pcall(fn)
	if not ok then
		error(string.format("%s\n    error inesperado: %s", message or "assertDoesNotThrow falló", tostring(err)), 2)
	end
end

TestFramework.Assert = Assert

-- Runner
function TestFramework:run(): TestResults
	local startTime = os.clock()

	print("=======================================")
	print("   EJECUTANDO SUITE DE TESTS")
	print("=======================================")

	local totalPassed = 0
	local totalFailed = 0
	local totalSkipped = 0
	local failedDetails: { { suite: string, test: string, error: string } } = {}

	for _, suite in ipairs(self.suites) do
		print(string.format("\n> %s", suite.name))
		for _, test in ipairs(suite.tests) do
			if test.skip then
				totalSkipped += 1
				print(string.format("  - (skip) %s", test.name))
			else
				local ok, err = pcall(test.fn)
				if ok then
					totalPassed += 1
					print(string.format("  [OK]   %s", test.name))
				else
					totalFailed += 1
					print(string.format("  [FAIL] %s", test.name))
					print(string.format("         %s", tostring(err)))
					table.insert(failedDetails, { suite = suite.name, test = test.name, error = tostring(err) })
				end
			end
		end
	end

	local duration = os.clock() - startTime

	print("\n=======================================")
	print(
		string.format(
			"RESULTADOS: %d OK · %d fallidos · %d saltados · %d totales (%.3fs)",
			totalPassed,
			totalFailed,
			totalSkipped,
			totalPassed + totalFailed + totalSkipped,
			duration
		)
	)
	print("=======================================")

	if totalFailed > 0 then
		print("\nDetalle de fallos:")
		for _, d in ipairs(failedDetails) do
			print(string.format("  [%s] %s\n      -> %s", d.suite, d.test, d.error))
		end
	end

	return {
		passed = totalPassed,
		failed = totalFailed,
		skipped = totalSkipped,
		total = totalPassed + totalFailed + totalSkipped,
		success = totalFailed == 0,
		durationSeconds = duration,
	}
end

--============================================================
-- SECCIÓN 2: SCRIPT DE EJEMPLO A TESTEAR
-- (Reemplazá esto por tu propio script real)
--============================================================
local MiScript = {}

-- Suma dos números
function MiScript.sumar(a: number, b: number): number
	return a + b
end

-- División con manejo de error explícito (división por cero)
function MiScript.dividir(a: number, b: number): number
	if b == 0 then
		error("MiScript.dividir: no se puede dividir por cero")
	end
	return a / b
end

-- Clamp: acota un valor entre un mínimo y un máximo
function MiScript.clamp(valor: number, minimo: number, maximo: number): number
	if minimo > maximo then
		error("MiScript.clamp: 'minimo' no puede ser mayor que 'maximo'")
	end
	return math.clamp(valor, minimo, maximo)
end

-- Invierte un string
function MiScript.invertirTexto(texto: string): string
	return string.reverse(texto)
end

-- Cuenta palabras separadas por espacios (colapsa espacios múltiples)
function MiScript.contarPalabras(texto: string): number
	if texto == "" then
		return 0
	end
	local _, count = texto:gsub("%S+", "")
	return count
end

-- Devuelve el elemento más grande de una lista de números
function MiScript.maximo(lista: { number }): number
	if #lista == 0 then
		error("MiScript.maximo: la lista está vacía")
	end
	local m = lista[1]
	for i = 2, #lista do
		if lista[i] > m then
			m = lista[i]
		end
	end
	return m
end

-- Filtra una tabla según un predicado
function MiScript.filtrar<T>(lista: { T }, predicado: (T) -> boolean): { T }
	local resultado = {}
	for _, v in ipairs(lista) do
		if predicado(v) then
			table.insert(resultado, v)
		end
	end
	return resultado
end

--============================================================
-- SECCIÓN 3: TESTS (cubren todas las posibilidades de cada función)
--   Checklist por función: normal · bordes (0/min/max) · negativos ·
--   vacíos (""/{}/nil) · extremos (huge/NaN) · debe-lanzar-error ·
--   no-debe-lanzar-error · integración con otras funciones
--============================================================
local t = TestFramework.new()

t:describe("MiScript.sumar", function(suite)
	suite.it("caso normal: suma dos positivos", function()
		Assert.equal(MiScript.sumar(2, 3), 5)
	end)

	suite.it("con negativos", function()
		Assert.equal(MiScript.sumar(-2, -3), -5)
	end)

	suite.it("positivo + negativo", function()
		Assert.equal(MiScript.sumar(10, -4), 6)
	end)

	suite.it("con cero", function()
		Assert.equal(MiScript.sumar(0, 0), 0)
		Assert.equal(MiScript.sumar(5, 0), 5)
	end)

	suite.it("con decimales", function()
		Assert.near(MiScript.sumar(0.1, 0.2), 0.3, 1e-9)
	end)

	suite.it("con números extremos", function()
		Assert.equal(MiScript.sumar(math.huge, 1), math.huge)
		Assert.isTrue(MiScript.sumar(-math.huge, -1) == -math.huge)
	end)

	suite.it("NaN nunca es igual a sí mismo (caso raro pero real)", function()
		local nan = 0 / 0
		local resultado = MiScript.sumar(nan, 1)
		Assert.isTrue(resultado ~= resultado, "se esperaba NaN")
	end)
end)

t:describe("MiScript.dividir", function(suite)
	suite.it("caso normal", function()
		Assert.equal(MiScript.dividir(10, 2), 5)
	end)

	suite.it("resultado con decimales", function()
		Assert.near(MiScript.dividir(1, 3), 0.3333333, 1e-6)
	end)

	suite.it("dividendo negativo", function()
		Assert.equal(MiScript.dividir(-10, 2), -5)
	end)

	suite.it("divisor negativo", function()
		Assert.equal(MiScript.dividir(10, -2), -5)
	end)

	suite.it("dividir cero por algo da cero", function()
		Assert.equal(MiScript.dividir(0, 5), 0)
	end)

	suite.it("dividir por cero debe lanzar error", function()
		Assert.throws(function()
			MiScript.dividir(10, 0)
		end, "dividir por cero")
	end)

	suite.it("no lanza error en caso normal", function()
		Assert.doesNotThrow(function()
			MiScript.dividir(4, 2)
		end)
	end)
end)

t:describe("MiScript.clamp", function(suite)
	suite.it("valor dentro del rango queda igual", function()
		Assert.equal(MiScript.clamp(5, 0, 10), 5)
	end)

	suite.it("valor por debajo del mínimo se ajusta al mínimo", function()
		Assert.equal(MiScript.clamp(-5, 0, 10), 0)
	end)

	suite.it("valor por encima del máximo se ajusta al máximo", function()
		Assert.equal(MiScript.clamp(50, 0, 10), 10)
	end)

	suite.it("valor exactamente en el borde inferior", function()
		Assert.equal(MiScript.clamp(0, 0, 10), 0)
	end)

	suite.it("valor exactamente en el borde superior", function()
		Assert.equal(MiScript.clamp(10, 0, 10), 10)
	end)

	suite.it("mínimo == máximo fuerza un único valor posible", function()
		Assert.equal(MiScript.clamp(999, 5, 5), 5)
	end)

	suite.it("mínimo > máximo debe lanzar error", function()
		Assert.throws(function()
			MiScript.clamp(5, 10, 0)
		end, "minimo")
	end)

	suite.it("rango con negativos", function()
		Assert.equal(MiScript.clamp(-50, -10, -1), -10)
	end)
end)

t:describe("MiScript.invertirTexto", function(suite)
	suite.it("caso normal", function()
		Assert.equal(MiScript.invertirTexto("hola"), "aloh")
	end)

	suite.it("string vacío", function()
		Assert.equal(MiScript.invertirTexto(""), "")
	end)

	suite.it("un solo carácter", function()
		Assert.equal(MiScript.invertirTexto("x"), "x")
	end)

	suite.it("palíndromo se mantiene igual", function()
		Assert.equal(MiScript.invertirTexto("ana"), "ana")
	end)

	suite.it("con espacios y símbolos", function()
		Assert.equal(MiScript.invertirTexto("a b-c"), "c-b a")
	end)

	suite.it("string largo (stress)", function()
		local largo = string.rep("ab", 10000)
		local invertido = MiScript.invertirTexto(largo)
		Assert.equal(#invertido, #largo)
		Assert.equal(MiScript.invertirTexto(invertido), largo)
	end)
end)

t:describe("MiScript.contarPalabras", function(suite)
	suite.it("caso normal", function()
		Assert.equal(MiScript.contarPalabras("hola mundo cruel"), 3)
	end)

	suite.it("string vacío da 0", function()
		Assert.equal(MiScript.contarPalabras(""), 0)
	end)

	suite.it("solo espacios da 0", function()
		Assert.equal(MiScript.contarPalabras("     "), 0)
	end)

	suite.it("espacios múltiples entre palabras no rompen el conteo", function()
		Assert.equal(MiScript.contarPalabras("hola     mundo"), 2)
	end)

	suite.it("una sola palabra", function()
		Assert.equal(MiScript.contarPalabras("hola"), 1)
	end)

	suite.it("con espacios al principio y al final", function()
		Assert.equal(MiScript.contarPalabras("  hola mundo  "), 2)
	end)
end)

t:describe("MiScript.maximo", function(suite)
	suite.it("caso normal", function()
		Assert.equal(MiScript.maximo({ 3, 1, 4, 1, 5, 9, 2, 6 }), 9)
	end)

	suite.it("lista de un solo elemento", function()
		Assert.equal(MiScript.maximo({ 42 }), 42)
	end)

	suite.it("todos negativos", function()
		Assert.equal(MiScript.maximo({ -5, -1, -10 }), -1)
	end)

	suite.it("con duplicados del máximo", function()
		Assert.equal(MiScript.maximo({ 7, 7, 7 }), 7)
	end)

	suite.it("máximo al principio, en medio y al final (orden no afecta)", function()
		Assert.equal(MiScript.maximo({ 9, 1, 2 }), 9)
		Assert.equal(MiScript.maximo({ 1, 9, 2 }), 9)
		Assert.equal(MiScript.maximo({ 1, 2, 9 }), 9)
	end)

	suite.it("lista vacía debe lanzar error", function()
		Assert.throws(function()
			MiScript.maximo({})
		end, "vacía")
	end)
end)

t:describe("MiScript.filtrar", function(suite)
	suite.it("caso normal: números pares", function()
		local resultado = MiScript.filtrar({ 1, 2, 3, 4, 5, 6 }, function(n)
			return n % 2 == 0
		end)
		Assert.deepEqual(resultado, { 2, 4, 6 })
	end)

	suite.it("lista vacía devuelve lista vacía", function()
		local resultado = MiScript.filtrar({}, function(n)
			return true
		end)
		Assert.deepEqual(resultado, {})
	end)

	suite.it("predicado que rechaza todo devuelve lista vacía", function()
		local resultado = MiScript.filtrar({ 1, 2, 3 }, function(n)
			return false
		end)
		Assert.equal(#resultado, 0)
	end)

	suite.it("predicado que acepta todo devuelve la lista completa", function()
		local resultado = MiScript.filtrar({ 1, 2, 3 }, function(n)
			return true
		end)
		Assert.deepEqual(resultado, { 1, 2, 3 })
	end)

	suite.it("funciona con strings, no solo números", function()
		local resultado = MiScript.filtrar({ "a", "bb", "ccc" }, function(s)
			return #s > 1
		end)
		Assert.deepEqual(resultado, { "bb", "ccc" })
	end)

	suite.it("no muta la lista original", function()
		local original = { 1, 2, 3 }
		MiScript.filtrar(original, function(n)
			return n > 1
		end)
		Assert.deepEqual(original, { 1, 2, 3 })
	end)
end)

t:describe("Integración entre funciones", function(suite)
	suite.it("clamp del resultado de una división", function()
		local resultado = MiScript.dividir(100, 3)
		local acotado = MiScript.clamp(resultado, 0, 10)
		Assert.equal(acotado, 10)
	end)

	suite.it("filtrar + maximo encadenados", function()
		local pares = MiScript.filtrar({ 5, 8, 3, 12, 7, 20 }, function(n)
			return n % 2 == 0
		end)
		Assert.equal(MiScript.maximo(pares), 20)
	end)
end)

--============================================================
-- SECCIÓN 4: EJECUCIÓN
--============================================================
local resultados = t:run()

if not resultados.success then
	print(string.format("\n%d test(s) fallaron.", resultados.failed))
	if type(os) == "table" and type((os :: any).exit) == "function" then
		(os :: any).exit(1)
	end
else
	print("\nTodos los tests pasaron correctamente.")
	if type(os) == "table" and type((os :: any).exit) == "function" then
		(os :: any).exit(0)
	end
end
