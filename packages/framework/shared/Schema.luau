--!strict
--[[
	Config / item-field schema language (pure). Extends the small type-string style ConfigValidate
	uses today (module-api.md §11) to a declarative, per-key form:

	  "number" "integer" "string" "boolean" "table" "function" "any"
	  "T?"                  optional (nil allowed)
	  "{T}"                 list of T
	  "{[string]: T}"       map string -> T
	  '"multiply"|"add"'    enum of string literals   (also: "enum(multiply,add)")
	  "number(0..1)"        number range (inclusive); "integer(1..)", "number(..10)" open ends
	  { type = "<type string>", description = "...", default = ... }   a described key
	  { key = <entry>, ... }                                            nested schema table

	Schema.parse(typeString) -> (node?, err?)
	Schema.checkSchema(schema, path, errors)          validates a schema itself (defineModule)
	Schema.validate(schema, value, path, errors, warnings)
	    validates `value` (a table) against `schema`; appends every problem (never fail-fast);
	    unknown keys go to `warnings` ("typo?") rather than errors, per §11.
]]

local Schema = {}

export type Node = {
	kind: "prim" | "list" | "map" | "enum" | "range",
	name: string?,
	of: Node?,
	values: { string }?,
	min: number?,
	max: number?,
	integer: boolean?,
	optional: boolean,
}

local PRIMS = {
	number = true,
	integer = true,
	string = true,
	boolean = true,
	table = true,
	["function"] = true,
	any = true,
}

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function parseInner(s: string): (Node?, string?)
	s = trim(s)
	local optional = false
	if string.sub(s, -1) == "?" then
		optional = true
		s = trim(string.sub(s, 1, -2))
	end
	local mapInner = string.match(s, "^{%s*%[%s*string%s*%]%s*:%s*(.+)}$")
	if mapInner then
		local of, err = parseInner(mapInner)
		if not of then
			return nil, err
		end
		return { kind = "map", of = of, optional = optional }, nil
	end
	local listInner = string.match(s, "^{(.+)}$")
	if listInner then
		local of, err = parseInner(listInner)
		if not of then
			return nil, err
		end
		return { kind = "list", of = of, optional = optional }, nil
	end
	if string.find(s, "|", 1, true) then
		local values = {}
		for part in string.gmatch(s, "[^|]+") do
			local lit = string.match(trim(part), '^"([^"]*)"$')
			if lit == nil then
				return nil, `enum member {trim(part)} must be a quoted string literal`
			end
			table.insert(values, lit)
		end
		return { kind = "enum", values = values, optional = optional }, nil
	end
	local fname, args = string.match(s, "^(%a+)%((.*)%)$")
	if fname == "enum" then
		local values = {}
		for part in string.gmatch(args :: string, "[^,]+") do
			table.insert(values, trim(part))
		end
		if #values == 0 then
			return nil, "enum() needs at least one value"
		end
		return { kind = "enum", values = values, optional = optional }, nil
	elseif fname == "number" or fname == "integer" then
		local lo, hi = string.match(args :: string, "^%s*(%-?[%d%.]*)%s*%.%.%s*(%-?[%d%.]*)%s*$")
		if lo == nil then
			return nil, `range {s} must look like number(min..max)`
		end
		local min = if lo == "" then nil else tonumber(lo)
		local max = if hi == "" then nil else tonumber(hi)
		if (lo ~= "" and min == nil) or (hi ~= "" and max == nil) then
			return nil, `range {s} has a bad bound`
		end
		return { kind = "range", min = min, max = max, integer = fname == "integer", optional = optional },
			nil
	elseif fname ~= nil then
		return nil, `unknown schema function {fname}()`
	end
	if PRIMS[s] then
		return { kind = "prim", name = s, optional = optional }, nil
	end
	return nil, `unknown type '{s}'`
end

local cache: { [string]: Node } = {}

function Schema.parse(typeString: string): (Node?, string?)
	local hit = cache[typeString]
	if hit then
		return hit, nil
	end
	local node, err = parseInner(typeString)
	if node then
		cache[typeString] = node
	end
	return node, err
end

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function describe(node: Node): string
	local base
	if node.kind == "prim" then
		base = node.name :: string
	elseif node.kind == "list" then
		base = "{" .. describe(node.of :: Node) .. "}"
	elseif node.kind == "map" then
		base = "{[string]: " .. describe(node.of :: Node) .. "}"
	elseif node.kind == "enum" then
		base = "one of " .. table.concat(node.values :: { string }, ", ")
	else
		base = `{if node.integer then "integer" else "number"}({node.min or ""}..{node.max or ""})`
	end
	return base
end
Schema.describe = describe

-- Returns nil when ok, else an error message (without the path).
local function checkNode(node: Node, value: any, path: string, errors: { string })
	if value == nil then
		if not node.optional then
			table.insert(errors, `{path}: required {describe(node)}, missing`)
		end
		return
	end
	local function bad()
		table.insert(errors, `{path}: expected {describe(node)}, got {typeof(value)} {tostring(value)}`)
	end
	if node.kind == "prim" then
		local n = node.name
		if n == "any" then
			return
		elseif n == "number" then
			if not isFinite(value) then
				bad()
			end
		elseif n == "integer" then
			if not isFinite(value) or value % 1 ~= 0 then
				bad()
			end
		elseif type(value) ~= n then
			bad()
		end
	elseif node.kind == "range" then
		local outOfRange = isFinite(value)
			and ((node.min and value < node.min) or (node.max and value > node.max))
		if not isFinite(value) or (node.integer and value % 1 ~= 0) or outOfRange then
			bad()
		end
	elseif node.kind == "enum" then
		if type(value) ~= "string" or table.find(node.values :: { string }, value) == nil then
			bad()
		end
	elseif node.kind == "list" then
		if type(value) ~= "table" then
			bad()
			return
		end
		local n = #value
		for k, v in value do
			if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
				table.insert(errors, `{path}: expected a list, found key {tostring(k)}`)
			else
				checkNode(node.of :: Node, v, `{path}[{k}]`, errors)
			end
		end
	elseif node.kind == "map" then
		if type(value) ~= "table" then
			bad()
			return
		end
		for k, v in value do
			if type(k) ~= "string" then
				table.insert(errors, `{path}: map keys must be strings, found {tostring(k)}`)
			else
				checkNode(node.of :: Node, v, `{path}.{k}`, errors)
			end
		end
	end
end

-- A described key: { type = "<string>", description?, default? }.
local function isDescriptor(entry: any): boolean
	return type(entry) == "table" and type(entry.type) == "string" and Schema.parse(entry.type) ~= nil
end

function Schema.checkSchema(schema: any, path: string, errors: { string })
	if type(schema) ~= "table" then
		table.insert(errors, `{path} must be a table of key -> type`)
		return
	end
	for key, entry in schema do
		local where = `{path}.{tostring(key)}`
		if type(key) ~= "string" then
			table.insert(errors, `{where}: schema keys must be strings`)
		elseif type(entry) == "string" then
			local _, err = Schema.parse(entry)
			if err then
				table.insert(errors, `{where}: {err}`)
			end
		elseif isDescriptor(entry) then
			if entry.description ~= nil and type(entry.description) ~= "string" then
				table.insert(errors, `{where}.description must be a string`)
			end
		elseif type(entry) == "table" then
			if type(entry.type) == "string" then
				local _, err = Schema.parse(entry.type)
				table.insert(errors, `{where}.type: {err}`)
			else
				Schema.checkSchema(entry, where, errors)
			end
		else
			table.insert(
				errors,
				`{where}: must be a type string, a {"{"} type = ... {"}"} descriptor or a nested schema`
			)
		end
	end
end

function Schema.validate(schema: any, value: any, path: string, errors: { string }, warnings: { string }?)
	if type(value) ~= "table" then
		table.insert(errors, `{path}: expected a table, got {typeof(value)}`)
		return
	end
	for key, entry in schema do
		local where = `{path}.{key}`
		local v = value[key]
		if type(entry) == "string" or isDescriptor(entry) then
			local node = Schema.parse(if type(entry) == "string" then entry else entry.type)
			if node then
				checkNode(node, v, where, errors)
			end
		elseif type(entry) == "table" then
			if v == nil then
				-- a nested schema whose every key is optional may be omitted
				local probe: { string } = {}
				Schema.validate(entry, {}, where, probe, nil)
				for _, e in probe do
					table.insert(errors, e)
				end
			else
				Schema.validate(entry, v, where, errors, warnings)
			end
		end
	end
	if warnings then
		for key in value do
			if schema[key] == nil then
				table.insert(warnings, `{path}.{tostring(key)}: unknown key (typo?), ignored by the schema`)
			end
		end
	end
end

-- Validates one value against one schema entry (used for defaults).
function Schema.checkEntry(entry: any, value: any, path: string, errors: { string })
	if type(entry) == "string" or isDescriptor(entry) then
		local node = Schema.parse(if type(entry) == "string" then entry else entry.type)
		if node then
			checkNode(node, value, path, errors)
		end
	elseif type(entry) == "table" and value ~= nil then
		Schema.validate(entry, value, path, errors, errors)
	end
end

return Schema
